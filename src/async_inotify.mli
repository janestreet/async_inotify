(** Async-friendly bindings to inotify, see [man 7 inotify].

    Be aware that the interface of inotify makes it easy to write code with race
    conditions or other subtle pitfalls. For instance, stat'ing a file then watching it
    means you have lost any events between the stat and the watch. Or the behavior when
    watching a path whose inode has multiple hardlinks is non-obvious. *)

open! Core
open! Async

type t
type file_info = string * Unix.Stats.t

module Event : sig
  module Selector : sig
    (** Which events we want to get. It is generally preferable to filter as much as
        possible at this level, instead of by filtering the events in the pipe, because it
        reduces the risk of queue overflows. *)
    type t =
      | Created
      | Unlinked
      | Modified
      | Moved
    [@@deriving enumerate, sexp_of]
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
    (** Queue overflow means that you are not consuming events fast enough and just lost
        some of them. This means that some changes to files you want might go unnoticed *)
    | Queue_overflow
  [@@deriving sexp_of, compare, equal]

  val to_string : t -> string
end

type modify_event_selector =
  [ `Any_change
    (** Send a Modified event whenever the contents of the file changes (which can be very
        often when writing a large file) *)
  | `Closed_writable_fd
    (** Only send a Modify event when someone with a file descriptor with write permission
        to that file is closed. There are usually many fewer of these events (for large
        files), but they come later. *)
  ]

(** [create path] creates an inotify watching path. Returns

    - the inotify type t itself
    - the list of files currently being watched. By default, recursively watches all
      subdirectories of the given path. See [add_all] for caveats.
    - a pipe of all events coming from t

    When [watch_new_dirs], directories added after [create] will be watched.

    [~events] specifies how to watch [path] and its descendants. When [watch_new_dirs],
    this will always watch for [Created] and [Moved] events, even if not included in
    [events]. Note that the automatic inclusion of [Created] and [Moved] events if
    [watch_new_dirs] is only a property of [create]; subsequent calls to
    [add t]/[add_all t] will not automatically include these, even if [t] was created with
    [watch_new_dirs].

    [wait_to_consolidate_moves] specifies whether to wait a little bit after seeing a
    [Move (Away _)] event for the corresponding [Move (Into, _)] event, so you are more
    likely to get a single [Move (Move _)]. *)
val create
  :  ?modify_event_selector:modify_event_selector (** default: [`Any_change] *)
  -> ?recursive:bool (** default: [true] *)
  -> ?watch_new_dirs:bool (** default: [true] *)
  -> ?events:Event.Selector.t list (** default: [Event.Selector.all] *)
  -> ?wait_to_consolidate_moves:Time_float.Span.t
  -> string
  -> (t * file_info list * Event.t Pipe.Reader.t) Deferred.t

(** [create_empty modify_event_selector] creates an inotify that watches nothing until
    [add] or [add_all] is called.

    It returns the pipe of all events coming from t. *)
val create_empty
  :  ?watch_new_dirs:bool (** default: [false] *)
  -> ?wait_to_consolidate_moves:Time_float.Span.t
  -> modify_event_selector:modify_event_selector
  -> unit
  -> (t * Event.t Pipe.Reader.t) Deferred.t

(** [stop t] stops watching for notifications. The pipe of events is closed once all
    remaining have been read. Any use of [add]/[remove] from this point will raise. *)
val stop : t -> unit Deferred.t

val stopped : t -> bool

(** [add t path] add the path to t to be watched *)
val add
  :  ?events:Event.Selector.t list (** default: [Event.Selector.all] *)
  -> t
  -> string
  -> unit Deferred.t

(** [add_all t path] watches [path] and all its current subdirectories recursively. This
    may generate events in the event pipe that are older than the returned file info, in
    the presence of concurrent modification to the filesystem. *)
val add_all
  :  ?on_open_errors:Async_find.Options.error_handler (** Default: [Print] *)
  -> ?on_stat_errors:Async_find.Options.error_handler (** Default: [Print] *)
  -> ?skip_dir:(string * Unix.Stats.t -> bool Deferred.t)
  -> ?events:Event.Selector.t list (** default: [Event.Selector.all] *)
  -> t
  -> string
  -> file_info list Deferred.t

(** [remove t path] remove the path from t *)
val remove : t -> string -> unit Deferred.t
