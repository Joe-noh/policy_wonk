defmodule PolicyWonk.LoadResource do

  @error_handler  Application.get_env(:slinger, Policy)[:error_handler]
  @app_loader     Application.get_env(:slinger, Policy)[:loader]
  @load_async     Application.get_env(:slinger, Policy)[:async]

  #----------------------------------------------------------------------------
  def init(opts) when is_map(opts) do
    # explicitly copy map options over. reduces to just the ones I know.
    %{
      resource_list:  prep_resource_list( opts[:resources] ),
      loader:         opts[:loader],
      async:          opts[:async] || @load_async,
      error_handler:  opts[:error_handler] || @error_handler
    }
  end
  def init(opts) when is_list(opts) do
    # incoming opts is a list of resources. prep/filter list, and pass back in a map
    # opts must be a list of strings or atoms...
    %{
      resource_list:  prep_resource_list(opts),
      loader:         nil,
      async:          @load_async,
      error_handler:  @error_handler
    }
  end
  def init(opts) when is_bitstring(opts),  do: init( [String.to_atom(opts)] )
  def init(opts) when is_atom(opts),       do: init( [opts] )
  #--------------------------------------------------------
  defp prep_resource_list( list ) do
    case list do
      nil -> []
      list ->
        Enum.filter_map(list, fn(res) ->
            # the filter
            cond do
              is_bitstring(res) -> true
              is_atom(res)      -> true
              true              -> false    # all other types
            end
          end, fn(res) ->
            # the mapper
            cond do
              is_bitstring(res) -> String.to_atom(res)
              is_atom(res)      -> res
            end
          end)
    end
    |> Enum.uniq
  end


  #----------------------------------------------------------------------------
  def call(conn, opts) do
    # get the correct module to handle the policies. Use, in order...
      # the specified loader in opts
      # the controller, if one is set. Will be nil if in the router
      # the global loader set in config
      # the router itself
    loader =
      opts[:loader] ||
      conn.private[:phoenix_controller] ||
      @app_loader ||
      conn.private[:phoenix_router]
    unless loader do
      raise "unable to find a resource loader module"
    end

    # load the resources. May be async
    cond do
      opts.async ->   async_loader(conn, loader, opts.resource_list)
      true ->         sync_loader(conn, loader, opts.resource_list)
    end
  end # def call

  #----------------------------------------------------------------------------
  defp async_loader(conn, loader, resource_list) do
    # asynch version of the loader. use filter_map to build a list of loader
    # tasks that are only for non-already-loaded resources. Then wait for all
    # of those asynchronous tasks to complete. This is part of why I love Elixir

    # spin up tasks for all the loads
    res_tasks = Enum.filter_map( resource_list, fn(res_type) ->
          # the filter
          conn.assigns[res_type] == nil
        end, fn(res_type) ->
          # the mapper
          task = Task.async( fn -> loader.load_resource(conn, res_type, conn.params) end )
          {res_type, task}
        end)

    # wait for the async tasks to complete
    Enum.reduce_while( res_tasks, conn, fn ({res_type, task}, acc_conn )->
        assign_resource(
          acc_conn,
          res_type,
          Task.await(task)
        )
      end)
  end

  #----------------------------------------------------------------------------
  defp sync_loader(conn, loader, resource_list) do
    # wait for the async tasks to complete
    Enum.reduce_while( resource_list, conn, fn (res_type, acc_conn )->
        assign_resource(
          acc_conn,
          res_type,
          loader.load_resource(acc_conn, res_type, acc_conn.params)
        )
      end)
  end

  #----------------------------------------------------------------------------
  defp assign_resource(conn, resource_id, resource) do
    case resource do
      nil ->
        case @error_handler do
          nil -> raise "No Policy Error handler defined"
          handler ->
            # failed to load the resource. return a 404
            {:halt, Plug.Conn.halt(handler.resource_not_found(conn))}
        end
      resource ->
        {:cont, Plug.Conn.assign(conn, resource_id, resource)}
    end
  end

end








