open Core
open Async

let read1 pipe =
  Clock.with_timeout (sec 2.) (Pipe.read pipe)
  >>| function
  | `Timeout -> raise_s [%sexp "timeout"]
  | `Result `Eof -> raise_s [%sexp "Eof"]
  | `Result (`Ok a) -> a
;;

let print value = print_s [%sexp (value : Async_inotify.Event.t)]
let print1 pipe = read1 pipe >>| print

let expect_one_of choices event =
  if List.mem choices event ~equal:Async_inotify.Event.equal
  then print_s [%sexp "one_of", (choices : Async_inotify.Event.t list)]
  else print_s [%sexp "unmatched", (event : Async_inotify.Event.t)]
;;

let mkdir dir = Unix.mkdir ~p:() dir
let touch file = Process.run_expect_no_output_exn ~prog:"touch" ~args:[ file ] ()
let rm file = Process.run_expect_no_output_exn ~prog:"rm" ~args:[ "-rf"; file ] ()
let mv a b = Process.run_expect_no_output_exn ~prog:"mv" ~args:[ a; b ] ()

let with_temp_dir f =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let%bind () = Sys.chdir dir in
    f ())
;;

let with_inotify dir f =
  let%bind inotify, stats, pipe =
    Async_inotify.create ~wait_to_consolidate_moves:(sec 1.) dir
  in
  let%bind () = f ~inotify ~stats ~pipe in
  let%bind () = Async_inotify.stop inotify in
  let%bind rest = Pipe.to_list pipe in
  List.iter rest ~f:(fun v -> print_s [%sexp (v : Async_inotify.Event.t)]);
  return ()
;;

let%expect_test "create, modify, move, and remove tests" =
  with_temp_dir (fun () ->
    let file_a = "file_a" in
    let file_b = "file_b" in
    let file_c = "file_c" in
    let%bind () = Writer.save file_a ~contents:"" in
    let%bind () =
      with_inotify "." (fun ~inotify:_ ~stats ~pipe ->
        let initial_files = List.map stats ~f:fst in
        print_s [%sexp (initial_files : string list)];
        [%expect "(./file_a)"];
        let%bind file_b_writer = Writer.open_file file_b in
        let%bind () = print1 pipe in
        [%expect "(Created ./file_b)"];
        Writer.write file_b_writer "modified";
        let%bind () = Writer.close file_b_writer in
        let%bind () = print1 pipe in
        [%expect "(Modified ./file_b)"];
        let%bind () = Sys.rename file_a file_c in
        let%bind () = print1 pipe in
        [%expect "(Moved (Move ./file_a ./file_c))"];
        let%bind () = Sys.remove file_c in
        let%bind () = print1 pipe in
        [%expect "(Unlinked ./file_c)"];
        return ())
    in
    [%expect ""];
    return ())
;;

let%expect_test "remove monitored dir" =
  with_temp_dir (fun () ->
    let%bind () = mkdir "dir_a" in
    let%bind () =
      with_inotify "dir_a" (fun ~inotify:_ ~stats:_ ~pipe:_ ->
        let%bind () = rm "dir_a" in
        return ())
    in
    [%expect {| |}];
    return ())
;;

let%expect_test "rename monitored dir" =
  with_temp_dir (fun () ->
    let%bind () = mkdir "dir_a" in
    let%bind () = touch "dir_a/file_0" in
    let%bind () =
      with_inotify "dir_a" (fun ~inotify:_ ~stats:_ ~pipe:_ ->
        let%bind () = mv "dir_a" "dir_b" in
        let%bind () = mv "dir_b" "dir_a" in
        (* The lib is unable to re-monitor the moved dir. But this might not be important
           to fix for now *)
        let%bind () = touch "dir_a/file_0" in
        return ())
    in
    [%expect
      {|
      (Moved (Away dir_a))
      (Moved (Away dir_a))
      |}];
    return ())
;;

let%expect_test "move nested dirs within the monitored dir" =
  with_temp_dir (fun () ->
    let%bind () =
      let%bind () = mkdir "dir_a" in
      let%bind () = touch "dir_a/file_0" in
      with_inotify "." (fun ~inotify:_ ~stats:_ ~pipe ->
        let print1 () = print1 pipe in
        let%bind () =
          mv "dir_a" "dir_b"
          >>= print1
          >>= print1
          >>= fun () ->
          read1 pipe >>| expect_one_of [ Moved (Away "./dir_a"); Moved (Away "./dir_b") ]
        in
        let%bind () = rm "dir_b/file_0" >>= print1 in
        let%bind () = touch "dir_b/file_1" >>= print1 in
        return ())
    in
    [%expect
      {|
      (Moved (Move ./dir_a ./dir_b))
      (Created ./dir_b/file_0)
      (one_of ((Moved (Away ./dir_a)) (Moved (Away ./dir_b))))
      (Unlinked ./dir_b/file_0)
      (Created ./dir_b/file_1)
      |}];
    return ())
;;

let%expect_test "move dir into monitored dir" =
  with_temp_dir (fun () ->
    let%bind () = mkdir "dir_a" in
    let%bind () =
      let%bind () = mkdir "dir_b" in
      let%bind () = touch "dir_b/file_0" in
      with_inotify "dir_a" (fun ~inotify:_ ~stats:_ ~pipe ->
        let print1 () = print1 pipe in
        let%bind () = mv "dir_b" "dir_a/" >>= print1 >>= print1 in
        let%bind () = rm "dir_a/dir_b/file_0" >>= print1 in
        let%bind () = touch "dir_a/dir_b/file_1" >>= print1 in
        return ())
    in
    [%expect
      {|
      (Moved (Into dir_a/dir_b))
      (Created dir_a/dir_b/file_0)
      (Unlinked dir_a/dir_b/file_0)
      (Created dir_a/dir_b/file_1)
      |}];
    return ())
;;
