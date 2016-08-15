module Test.Model exposing (tests)

import Arborist.Framework exposing (..)
import Arborist.Matchers exposing (..)
import Url
import Task

import Model exposing (Avatar (..), avatarLink)

tests : Tests
tests =
  [
    test "Model.avatarLink: a GitHub avatar link is parameterized with the correct size" (
      let
        avatar = GitHubAvatar (Url.parse "https://example.com/avatars/bob?v=3")
        expected = Url.parse "https://example.com/avatars/bob?s=24&v=3" |> Task.succeed
        actual = avatarLink avatar |> Task.succeed
      in
        assert actual (equals expected)
    )
  ]