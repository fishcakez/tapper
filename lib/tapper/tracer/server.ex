defmodule Tapper.Tracer.Server do
    use GenServer

    require Logger

    alias Tapper.Tracer.Trace
    alias Tapper.Tracer.Annotations

    @doc """
    Starts a Tracer, registering a name derived from the Tapper trace_id.

    NB called by Tapper.Tracer.Supervisor when starting a trace with `start_tracer/2`.
    """
    def start_link(config, trace_init = {trace_id, _, _, _, _}, pid, timestamp, opts) do
        Logger.debug(fn -> inspect {"Tracer: start_link", trace_init} end)
        GenServer.start_link(Tapper.Tracer.Server, [config, trace_init, pid, timestamp, opts], name: via_tuple(trace_id)) # calls Tapper.Tracer.Server.init/1
    end

    def via_tuple(%Tapper.Id{trace_id: trace_id}), do: via_tuple(trace_id)
    def via_tuple(trace_id) do
        {:via, Registry, {Tapper.Tracers, trace_id}}
    end

    @doc """
    Initializes the Tracer's state.

    NB passed the list of arguments supplied by `Tapper.Tracer.Server.start_link/4` via `Tapper.Tracer.Supervisor.start_tracer/3`.
    """
    def init([config, trace_init = {trace_id, span_id, parent_id, sample, debug}, _pid, timestamp, opts]) do
        Logger.debug(fn -> inspect {"Tracer: started tracer", trace_init} end)

        Logger.info("Start Trace #{Tapper.TraceId.format(trace_id)}")

        # this is the local host: can be overridden by a client, if needs to be dynamically generated.
        endpoint = opts[:endpoint] || endpoint_from_config(config)

        # we shouldn't be stopped by the exit of the process that started the trace because async
        # processes may still be processing; we use either an explicit `finish/1` or
        # the `ttl` option to terminate hanging traces.
        ttl = case Keyword.get(opts, :ttl) do
            ms when is_integer(ms) -> ms
            _ -> 30_000
        end

        span_info = initial_span_info(span_id, parent_id, timestamp, endpoint, opts)

        trace = %Trace{
            config: config,
            trace_id: trace_id,
            span_id: span_id,
            parent_id: parent_id,
            spans: %{
                span_id => span_info # put initial span in span-map
            },
            sample: sample,
            debug: debug,
            timestamp: timestamp,
            last_activity: timestamp,
            ttl: ttl
        }

        {:ok, trace, ttl}
    end

    def handle_info(:timeout, trace) do
        Logger.debug(fn -> inspect({trace.trace_id, :timeout}) end)

        trace = %Trace{trace | end_timestamp: trace.last_activity}

        # TODO clean-up spans?

        report_trace(trace)

        Logger.info("End Trace #{Tapper.TraceId.format(trace.trace_id)} (timeout)")
        {:stop, :normal, []}
    end

    @doc "via Tapper.Tracer.finish/2"
    # TODO support flush?
    def handle_cast(msg = {:finish, timestamp, _opts}, trace) do
        Logger.debug(fn -> inspect({trace.trace_id, msg}) end)

        trace = %Trace{trace | end_timestamp: timestamp}

        report_trace(trace)

        Logger.info("End Trace #{Tapper.TraceId.format(trace.trace_id)}")
        {:stop, :normal, []}
    end

    @doc "via start_span()"
    def handle_cast(msg = {:start_span, span_info, opts}, trace) do
        Logger.debug(fn -> inspect({Tapper.TraceId.format(trace.trace_id), msg}) end)

        span_info = case opts[:local] do
            val when is_binary(val) ->
                annotation = Trace.BinaryAnnotation.new(:lc, val, :string, endpoint_from_config(trace.config))
                update_in(span_info.binary_annotations, &([annotation | &1]))
            _ -> span_info
        end

        trace = put_in(trace.spans[span_info.id], span_info)
        trace = put_in(trace.last_activity, span_info.start_timestamp)

        {:noreply, trace, trace.ttl}
    end

    @doc "via Tapper.Tracer.finish_span/1"
    def handle_cast(msg = {:finish_span, span_info}, trace) do
        Logger.debug(fn -> inspect({trace.trace_id, msg}) end)

        trace = put_in(trace.spans[span_info.id].end_timestamp, span_info.end_timestamp)
        trace = put_in(trace.last_activity, span_info.end_timestamp)

        {:noreply, trace, trace.ttl}
    end

    @doc "via Tapper.Tracer.name/2"
    def handle_cast(msg = {:name, span_id, name, timestamp}, trace) do
        Logger.debug(fn -> inspect({trace.trace_id, msg}) end)

        trace = put_in(trace.spans[span_id].name, name)
        trace = put_in(trace.last_activity, timestamp)

        {:noreply, trace, trace.ttl}
    end

    @doc "via Tapper.Tracer.annotate"
    def handle_cast(msg = {:annotation, span_id, value, timestamp, endpoint}, trace) do
        Logger.debug(fn -> inspect({trace.trace_id, msg}) end)

        new_annotation = Annotations.annotation(value, timestamp, endpoint || endpoint_from_config(trace.config))

        trace = case new_annotation do
            nil -> trace
            _ ->
                trace = update_in(trace.spans[span_id].annotations, &([new_annotation | &1]))
                %{trace | last_activity: timestamp}
        end

        {:noreply, trace, trace.ttl}
    end

    @doc "via Tapper.Tracer.binary_annotate"
    def handle_cast(msg = {:binary_annotation, span_id, type, key, value, timestamp, endpoint}, trace) do
        Logger.debug(fn -> inspect({trace.trace_id, msg}) end)

        endpoint = endpoint || endpoint_from_config(trace.config)

        new_annotation = Annotations.binary_annotation(type, key, value, endpoint)

        trace = case new_annotation do
            nil -> trace
            _ ->
                trace = update_in(trace.spans[span_id].binary_annotations, &([new_annotation | &1]))
                %{trace | last_activity: timestamp}
        end

        {:noreply, trace, trace.ttl}
    end

    def endpoint_from_config(%{host_info: %{ipv4: ipv4, system_id: system_id}}) do
        %Tapper.Endpoint{
            ipv4: ipv4,
            service_name: system_id
        }
    end


    @doc "prepare the SpanInfo of the initial span in this Tracer"
    def initial_span_info(span_id, parent_id, timestamp, endpoint, opts) do

        annotation_type = case Keyword.get(opts, :type, :client) do
            :server -> :sr
            :client -> :cs
        end

        name = Keyword.get(opts, :name, "unknown")

        binary_annotations = add_remote_address_annotation([], annotation_type, opts)

        %Trace.SpanInfo {
            name: name,
            id: span_id,
            parent_id: parent_id,
            start_timestamp: timestamp,
            annotations: [%Trace.Annotation{
                timestamp: timestamp,
                value: annotation_type,
                host: endpoint
            }],
            binary_annotations: binary_annotations
        }
    end

    def add_remote_address_annotation(annotations, span_type, opts) do
        case {span_type, opts[:remote]} do
            {:sr, client_endpoint = %Tapper.Endpoint{} } ->
                [Annotations.binary_annotation(:ca, client_endpoint) | annotations]

            {:cs, server_endpoint= %Tapper.Endpoint{} } ->
                [Annotations.binary_annotation(:sa, server_endpoint) | annotations]

            _else -> annotations
        end
    end

    def report_trace(trace = %Trace{}) do
        Logger.debug(fn -> "Sending trace #{inspect trace}" end)

        spans = Trace.to_protocol_spans(trace)

        apply(trace.config.reporter, :ingest, [spans])
    end

end