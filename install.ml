#use "topfind";;
#require "js-build-tools.oasis2opam_install";;

open Oasis2opam_install;;

generate ~package:"async_inotify"
  [ oasis_lib "async_inotify"
  ; file "META" ~section:"lib"
  ; file "_build/namespace_wrappers/ocaml_inotify.cmi" ~section:"lib"
  ]
