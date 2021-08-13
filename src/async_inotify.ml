(* We don't make calls to [Inotify] functions ([add_watch], [rm_watch], [read]) in
   [In_thread.run] because:

   - we don't think they can block for a while
   - Inotify doesn't release the OCaml lock anyway
   - it avoids changes to the set of watches racing with the Inotify.read loop below, by
     preventing adding a watch and seeing an event about it before having filled the
     hashtable (not that we have observed this particular race). *)

open Core
open Async
module Inotify = Ocaml_inotify.Inotify

type modify_event_selector =
  [ `Any_change
  | `Closed_writable_fd
  ]

module Event = struct
  module Selector = struct
    type t =
      | Created
      | Unlinked
      | Modified
      | Moved
    [@@deriving enumerate, compare, sexp_of]

    let inotify_selectors ts modify_event_selector =
      List.dedup_and_sort ts ~compare
      |> List.concat_map ~f:(function
        | Created -> [ Inotify.S_Create ]
        | Unlinked -> [ S_Delete ]
        | Modified ->
          (match modify_event_selector with
           | `Any_change -> [ S_Modify ]
           | `Closed_writable_fd -> [ S_Close_write ])
        | Moved -> [ S_Move_self; S_Moved_from; S_Moved_to ])
    ;;
  end

  type move =
    | Away of string
    | Into of string
    | Move of string * string
  [@@deriving sexp_of]

  type t =
    | Created of string
    | Unlinked of string
    | Modified of string
    | Moved of move
    | Queue_overflow
  [@@deriving sexp_of]

  let move_to_string m =
    match m with
    | Away s -> sprintf "%s -> Unknown" s
    | Into s -> sprintf "Unknown -> %s" s
    | Move (f, t) -> sprintf "%s -> %s" f t
  ;;

  let to_string t =
    match t with
    | Created s -> sprintf "created %s" s
    | Unlinked s -> sprintf "unlinked %s" s
    | Moved mv -> sprintf "moved %s" (move_to_string mv)
    | Modified s -> sprintf "modified %s" s
    | Queue_overflow -> "queue overflow"
  ;;
end

open Event

module Watch = struct
  type t = Inotify.watch

  let compare t1 t2 = Int.compare (Inotify.int_of_watch t1) (Inotify.int_of_watch t2)
  let hash t = Int.hash (Inotify.int_of_watch t)
  let sexp_of_t t = sexp_of_int (Inotify.int_of_watch t)
end

type t =
  { fd : Fd.t
  ; watch_table : (Inotify.watch, string) Hashtbl.t
  ; path_table : Inotify.watch String.Table.t
  ; modify_event_selector : modify_event_selector
  ; default_selectors : Inotify.selector list
  }

type file_info = string * Unix.Stats.t

let add ?events t path =
  let watch =
    Fd.with_file_descr_exn t.fd (fun fd ->
      Inotify.add_watch
        fd
        path
        (match events with
         | None -> t.default_selectors
         | Some e -> Event.Selector.inotify_selectors e t.modify_event_selector))
  in
  Hashtbl.set t.watch_table ~key:watch ~data:path;
  Hashtbl.set t.path_table ~key:path ~data:watch;
  return ()
;;

(* adds all the directories under path (including path) to t *)
let add_all ?skip_dir ?events t path =
  let options =
    { Async_find.Options.default with
      on_open_errors = Print
    ; on_stat_errors = Print
    ; skip_dir
    }
  in
  let%bind () = add ?events t path in
  let f = Async_find.create ~options path in
  Async_find.fold f ~init:[] ~f:(fun files (fn, stat) ->
    match stat.kind with
    | `Directory ->
      let%map () = add ?events t fn in
      (fn, stat) :: files
    | _ -> return ((fn, stat) :: files))
;;

let remove t path =
  match Hashtbl.find t.path_table path with
  | None -> return ()
  | Some watch ->
    Fd.with_file_descr_exn t.fd (fun fd -> Inotify.rm_watch fd watch);
    Hashtbl.remove t.watch_table watch;
    Hashtbl.remove t.path_table path;
    return ()
;;

(* with streams, this was effectively infinite, so pick a big number  *)
let size_budget = 10_000_000

let raw_event_pipe t =
  Pipe.create_reader ~size_budget ~close_on_exception:false (fun w ->
    Deferred.repeat_until_finished () (fun () ->
      match%bind Fd.ready_to t.fd `Read with
      | `Bad_fd -> failwith "Bad Inotify file descriptor"
      | `Closed -> return (`Finished ())
      | `Ready ->
        (* Read in the async thread. We should reading memory, like what happens with
           pipes and sockets, and unlike what happens with files, and we should know
           that there's data. Ensure the fd is nonblock so the read raises instead of
           blocking async if something has gone wrong. *)
        (match Fd.with_file_descr ~nonblocking:true t.fd Inotify.read with
         | `Already_closed -> return (`Finished ())
         | `Error exn -> raise_s [%sexp "Inotify.read failed", (exn : Exn.t)]
         | `Ok events ->
           let ev_kinds =
             List.filter_map events ~f:(fun (watch, ev_kinds, trans_id, fn) ->
               (* queue overflow event is always reported on watch -1 *)
               if Inotify.int_of_watch watch = -1
               then (
                 let maybe_overflow =
                   List.filter_map ev_kinds ~f:(fun ev ->
                     match ev with
                     | Q_overflow -> Some (ev, trans_id, "<overflow>")
                     | _ -> None)
                 in
                 if List.is_empty maybe_overflow then None else Some maybe_overflow)
               else (
                 match Hashtbl.find t.watch_table watch with
                 | None ->
                   Print.eprintf
                     "Events for an unknown watch (%d) [%s]\n"
                     (Inotify.int_of_watch watch)
                     (String.concat
                        ~sep:", "
                        (List.map ev_kinds ~f:Inotify.string_of_event_kind));
                   None
                 | Some path ->
                   let fn =
                     match fn with
                     | None -> path
                     | Some fn -> path ^/ fn
                   in
                   Some (List.map ev_kinds ~f:(fun ev -> ev, trans_id, fn))))
             |> List.concat
           in
           let pending_mv, actions =
             List.fold
               ev_kinds
               ~init:(None, [])
               ~f:(fun (pending_mv, actions) (kind, trans_id, fn) ->
                 let add_pending lst =
                   match pending_mv with
                   | None -> lst
                   | Some (_, fn) -> Moved (Away fn) :: lst
                 in
                 match kind with
                 | Moved_from -> Some (trans_id, fn), add_pending actions
                 | Moved_to ->
                   (match pending_mv with
                    | None -> None, Moved (Into fn) :: actions
                    | Some (m_trans_id, m_fn) ->
                      if Int32.( = ) m_trans_id trans_id
                      then None, Moved (Move (m_fn, fn)) :: actions
                      else None, Moved (Away m_fn) :: Moved (Into fn) :: actions)
                 | Move_self -> Some (trans_id, fn), add_pending actions
                 | Create -> None, Created fn :: add_pending actions
                 | Delete -> None, Unlinked fn :: add_pending actions
                 | Modify | Close_write -> None, Modified fn :: add_pending actions
                 | Q_overflow -> None, Queue_overflow :: add_pending actions
                 | Delete_self -> None, add_pending actions
                 | Access | Attrib | Open | Ignored | Isdir | Unmount | Close_nowrite
                   -> None, add_pending actions)
           in
           let actions =
             List.rev
               (match pending_mv with
                | None -> actions
                | Some (_, fn) -> Moved (Away fn) :: actions)
           in
           List.iter actions ~f:(Pipe.write_without_pushback_if_open w);
           let%map () = Pipe.pushback w in
           `Repeat ())))
;;

let event_pipe ~watch_new_dirs ?events t =
  if not watch_new_dirs
  then raw_event_pipe t
  else
    Pipe.create_reader ~size_budget ~close_on_exception:false (fun w ->
      Pipe.iter (raw_event_pipe t) ~f:(function
        | (Queue_overflow | Unlinked _ | Moved _ | Modified _) as ev ->
          Pipe.write_if_open w ev
        | Created path ->
          (match%bind Monitor.try_with (fun () -> Unix.stat path) with
           | Error _ -> (* created file has already disappeared *) return ()
           | Ok stat ->
             (match stat.kind with
              | `File | `Char | `Block | `Link | `Fifo | `Socket ->
                Pipe.write_if_open w (Created path)
              | `Directory ->
                Pipe.write_without_pushback_if_open w (Created path);
                let%bind additions = add_all ?events t path in
                List.iter additions ~f:(fun (file, _stat) ->
                  Pipe.write_without_pushback_if_open w (Created file));
                Pipe.pushback w))))
;;

let create_internal ~modify_event_selector =
  let fd = Inotify.create () in
  let%map () = In_thread.run (fun () -> Core_unix.set_close_on_exec fd) in
  (* fstat an on inotify fd says the filetype is File, but we tell async Fifo instead.
     The reason is that async considers that for File, Fd.ready_to is meaningless and so
     should return immediately. So instead we say Fifo, because an inotify fd is basically
     the read end of a pipe whose write end is owned by the kernel, and more importantly,
     Fd.create knows that fifos support nonblocking. *)
  let fd = Fd.create Fifo fd (Info.of_string "async_inotify") in
  let watch_table = Hashtbl.create (module Watch) ~size:10 in
  { fd
  ; watch_table
  ; path_table = Hashtbl.create (module String) ~size:10
  ; modify_event_selector
  ; default_selectors =
      Event.Selector.inotify_selectors Event.Selector.all modify_event_selector
  }
;;

let create_empty ~modify_event_selector =
  let%map t = create_internal ~modify_event_selector in
  t, event_pipe ~watch_new_dirs:false t
;;

let create
      ?(modify_event_selector = `Any_change)
      ?(recursive = true)
      ?(watch_new_dirs = true)
      ?(events = Event.Selector.all)
      path
  =
  let events =
    if watch_new_dirs
    then Event.Selector.Created :: Event.Selector.Moved :: events
    else events
  in
  let%bind t = create_internal ~modify_event_selector in
  let skip_dir = if recursive then None else Some (fun _ -> return true) in
  let%map initial_files = add_all ?skip_dir ~events t path in
  t, initial_files, event_pipe ~watch_new_dirs ~events t
;;

let stop t = Fd.close t.fd
