-module(amoc_api_scenario_handler).

-behavior(trails_handler).

-export([trails/0]).

-export([init/3]).

-export([rest_init/2,
         allowed_methods/2,
         content_types_provided/2,
         content_types_accepted/2,
         resource_exists/2,
         to_json/2,
         from_json/2]).


-record(state, {resource, users}).

-type state() :: #state{}.

-spec trails() -> trails:trails().
trails() ->
    Id =
    #{name => <<"id">>,
      in => path,
      description => <<"Scenario id">>,
      type => string,
      required => true},

    RequestBody =
    #{name => <<"request body">>,
      in => body,
      description => <<"request body (as json)">>,
      required => true,
      schema =>
      #{type => <<"object">>,
        required => [<<"users">>],
        properties =>
        #{users => #{<<"type">> => <<"integer">>,
                     <<"description">> => <<"Number of users to start">>
                   }
        }
      }
    },

    ResponseBodyGet =
    #{<<"200">> =>
      #{description => <<"response object">>,
        schema =>
        #{type => <<"object">>,
          required => [<<"scenario_status">>],
          properties =>
          #{scenario_status => #{<<"type">> => <<"string">>,
                                 <<"description">> => 
                                   <<"loaded | running | finished">>
                               }
          }
        }
      }
    },

    ResponseBodyPatch =
    #{<<"200">> =>
      #{description => <<"response object">>,
        schema =>
        #{type => <<"object">>,
          required => [<<"scenario">>],
          properties =>
          #{scenario => #{<<"type">> => <<"string">>,
                          <<"description">> => <<"started | wrong_json">>
                        }
          }
        }
      }
    },

    Metadata =
    #{get =>
      #{tags => ["scenario"],
        description => "Gets scenario status",
        produces => ["application/json"],
        parameters => [Id],
        responses => ResponseBodyGet
      },
      patch =>
      #{tags => ["scenario"],
        description => "Starts scenario",
        produces => ["application/json"],
        parameters => [Id, RequestBody],
        responses => ResponseBodyPatch
      }
    },
    [trails:trail("/scenarios/:id", ?MODULE, [], Metadata)].

-spec init(tuple(), cowboy_req:req(), state()) ->
    {upgrade, protocol, cowboy_rest}.
init({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_rest}.

-spec rest_init(cowboy_req:req(), [atom()]) ->
    {ok, cowboy_req:req(), state()}.
rest_init(Req, _Opts) ->
    {ResourceB, Req2} = cowboy_req:binding(id, Req),
    Resource = erlang:binary_to_list(ResourceB),
    {ok, Req2, #state{resource = Resource}}.

-spec allowed_methods(cowboy_req:req(), state()) -> 
    {[binary()], cowboy_req:req(), state()}.
allowed_methods(Req, State) ->
    {[<<"PATCH">>, <<"GET">>], Req, State}.

-spec content_types_provided(cowboy_req:req(), state()) -> 
    {[tuple()], cowboy_req:req(), state()}.
content_types_provided(Req, State) ->
    {[{<<"application/json">>, to_json}], Req, State}.

-spec content_types_accepted(cowboy_req:req(), state()) -> 
    {[tuple()], cowboy_req:req(), state()}.
content_types_accepted(Req, State) ->
    {[{<<"application/json">>, from_json}], Req, State}.

-spec resource_exists(cowboy_req:req(), state()) ->
    {boolean(), cowboy_req:req(), state()}.
resource_exists(Req, State = #state{resource = Resource}) ->
    {ok, Files} = file:list_dir("scenarios/"),
    Pred = fun (File) -> File == Resource ++ ".erl" end,
    case lists:filter(Pred, Files) of
        [] ->
            {false, Req, State};
        [_File] ->
            {true, Req, State}
    end.



%% Request processing functions

-spec to_json(cowboy_req:req(), state()) -> 
    {iolist(), cowboy_req:req(), state()}.
to_json(Req0, State = #state{resource = Resource}) ->
    Status = amoc_dist:test_status(erlang:list_to_atom(Resource)),
    Reply = jiffy:encode({[{scenario_status, Status}]}),
    {Reply, Req0, State}.


-spec from_json(cowboy_req:req(), state()) ->
    {boolean(), cowboy_req:req(), state()}.
from_json(Req, State = #state{resource = Resource}) ->
    case get_users_from_body(Req) of
        {ok, Users, Req2} ->
            Scenario = erlang:list_to_atom(Resource),
            Result = amoc_dist:do(Scenario, 1, Users),
            Reply = jiffy:encode({[{scenario, get_result(Result)}]}),
            Req3 = cowboy_req:set_resp_body(Reply, Req2),
            {true, Req3, State};
        {error, bad_request, Req2} ->
            Reply = jiffy:encode({[{scenario, bad_request}]}),
            Req3 = cowboy_req:set_resp_body(Reply, Req2),
            {false, Req3, State}
    end.


%% internal function
-spec get_users_from_body(cowboy_req:req()) -> {ok, term(), cowboy_req:req()} |
        {error, bad_request, cowboy_req:req()}.
get_users_from_body(Req) ->
    {ok, Body, Req2} = cowboy_req:body(Req),
    try
        {JSON} = jiffy:decode(Body),
        Users = proplists:get_value(<<"users">>, JSON),
        true = is_integer(Users),
        {ok, Users, Req2}
    catch _:_ ->
              {error, bad_request, Req2}
    end.

-spec get_result([ok | {error, term()}]) -> started | error.
get_result(Result) ->
    Res = lists:all(fun(X) -> X == ok end, Result),
    case Res of
        true -> started;
        false ->
                Errors = lists:filter(fun(X) -> X =/= ok end, Result),
                lager:error("Run scenario error: ~p", [Errors]),
                error
    end. 
