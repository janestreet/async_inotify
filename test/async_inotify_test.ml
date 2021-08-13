open Core
open Async

let read1 pipe = Clock.with_timeout (sec 2.) (Pipe.read pipe)

let print value =
  print_s [%sexp (value : [ `Eof | `Ok of Async_inotify.Event.t ] Clock.Or_timeout.t)]
;;

let read_move_and_print pipe =
  (* If corresponding away and into events are in two separate batches instead of the same
     batch, they will not get combined into a single move event. This is essentially a
     async_inotify bug, but until that gets fixed, we need to account for it so the test
     is deterministic. *)
  let%bind ev1 = read1 pipe in
  match ev1 with
  | `Result (`Ok (Async_inotify.Event.Moved (Away away))) ->
    let%map ev2 = read1 pipe in
    (match ev2 with
     | `Result (`Ok (Moved (Into into))) ->
       print (`Result (`Ok (Async_inotify.Event.Moved (Move (away, into)))))
     | _ ->
       print ev1;
       print ev2)
  | _ ->
    print ev1;
    return ()
;;

let%expect_test "create, modify, move, and remove tests" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let%bind () = Sys.chdir dir in
    let file_a = "file_a" in
    let file_b = "file_b" in
    let file_c = "file_c" in
    let%bind () = Writer.save file_a ~contents:"" in
    let%bind inotify, stats, pipe = Async_inotify.create "." in
    let initial_files = List.map stats ~f:fst in
    print_s [%sexp (initial_files : string list)];
    [%expect "(./file_a)"];
    let%bind file_b_writer = Writer.open_file file_b in
    let%bind () = read1 pipe >>| print in
    [%expect "(Result (Ok (Created ./file_b)))"];
    Writer.write file_b_writer "modified";
    let%bind () = Writer.close file_b_writer in
    let%bind () = read1 pipe >>| print in
    [%expect "(Result (Ok (Modified ./file_b)))"];
    let%bind () = Sys.rename file_a file_c in
    let%bind () = read_move_and_print pipe in
    [%expect "(Result (Ok (Moved (Move ./file_a ./file_c))))"];
    let%bind () = Sys.remove file_c in
    let%bind () = read1 pipe >>| print in
    [%expect "(Result (Ok (Unlinked ./file_c)))"];
    let%bind () = Async_inotify.stop inotify in
    let%bind rest = Pipe.to_list pipe in
    List.iter rest ~f:(fun v -> print_s [%sexp (v : Async_inotify.Event.t)]);
    [%expect ""];
    return ())
;;
