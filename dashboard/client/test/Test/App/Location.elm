module Test.App.Location exposing (tests)

import Arborist.Framework exposing (..)
import Arborist.Matchers exposing (..)
import Task

import App.Location exposing (..)
import Navigation

tests : Tests
tests =
  [
    test "App.Location: parses the URL for Home" (
      let
        expected = Home |> Task.succeed
        actual = parse (locationWithPath "/") |> Task.succeed
      in
        assert actual (equals expected)
    ),

    test "App.Location: parses the URL for NewProject" (
      let
        expected = NewProject |> Task.succeed
        actual = parse (locationWithPath "/projects") |> Task.succeed
      in
        assert actual (equals expected)
    ),

    test "App.Location: parses the URL for Project" (
      let
        expected = Project "sandwiches" "pickles" |> Task.succeed
        actual = parse (locationWithPath "/projects/sandwiches/pickles") |> Task.succeed
      in
        assert actual (equals expected)
    ),

    test "App.Location: parses the URL for EditProject" (
      let
        expected = EditProject "sandwiches" "egg" |> Task.succeed
        actual = parse (locationWithPath "/projects/sandwiches/egg/edit") |> Task.succeed
      in
        assert actual (equals expected)
    ),

    test "App.Location: fails when the URL could not be parsed" (
      let
        actual = parse (locationWithPath "/not/gonna/work")
      in
        case actual of
          Unknown "/not/gonna/work" -> pass
          value -> failWith ("Got " ++ toString value)
    )
  ]

locationWithPath : String -> Navigation.Location
locationWithPath path =
  {
    href = "",
    host = "",
    hostname = "",
    protocol = "",
    origin = "",
    port_ = "",
    pathname = path,
    search = "",
    hash = "",
    username = "",
    password = ""
  }
