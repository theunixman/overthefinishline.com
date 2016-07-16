module Model exposing (..)

import Moment exposing (Moment)
import Result

import Error exposing (Error)

type Model = Loading
           | Error Error
           | Unauthenticated
           | Dashboard {
             now : Moment,
             pullRequests : PullRequests
           }

type alias PullRequests = List PullRequest
type alias PullRequest = {
    repository : Repository,
    number : Int,
    title : String,
    updatedAt : Moment,
    link : Link
  }
type alias Repository = {
    owner : String,
    name : String,
    link : Link
  }
type alias Link = String

createDashboard now pullRequests =
  Dashboard {
    now = now,
    pullRequests = pullRequests |> List.sortWith (\a b -> Moment.compare a.updatedAt b.updatedAt)
  }

dashboard
    : { now: Result String Moment,
        pullRequests: List { repository : Repository, number : Int, title : String, updatedAt : Result String Moment, link : Link } }
    -> Result String Model
dashboard {now, pullRequests} =
  let
    pullRequestsResult = pullRequests
      |> List.map (\record ->
           case record.updatedAt of
             Ok updatedAtMoment -> Ok { record | updatedAt = updatedAtMoment }
             Err error -> Err error)
      |> sequenceResults
  in
    Result.map2 createDashboard now pullRequestsResult

pullRequests
    : List { repository : Repository, number : Int, title : String, updatedAt : Result String Moment, link : Link }
    -> Result String PullRequests
pullRequests records =
  records
    |> List.map (\record ->
        case record.updatedAt of
          Ok date -> Ok { record | updatedAt = date }
          Err error -> Err error)
    |> sequenceResults

sequenceResults : List (Result a b) -> Result a (List b)
sequenceResults = List.foldr (Result.map2 (::)) (Ok [])
