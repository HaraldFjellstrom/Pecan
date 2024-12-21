defmodule Pecan.Router.SharedSend do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: args[:name])
  end

  @impl true
  def init(args) do
    sched_send(args[:interval])
    {id, _} = Integer.parse(String.slice(to_string(args[:name]), 1..-1//1))

    {:ok,
     %{
       id: id,
       eff: if(String.first(to_string(args[:name])) == "e", do: true, else: false),
       can_if: args[:can_if],
       interval: args[:interval],
       values: []
     }}
  end

  # Make surre data = 64 bit unsigned int
  def add_value(name, origin, data) do
    GenServer.cast(Process.whereis(name), {:add_value, origin, data})
  end

  def force_send(name) do
    GenServer.cast(Process.whereis(name), :force_send)
  end

  @impl true
  def handle_cast(:force_send, state) do
    Process.send(self(), :send, [])
    {:noreply, state}
  end

  @impl true
  def handle_cast({:add_value, origin, data}, state) do
    state =
      case Enum.find(state.values, fn map -> map.pid == origin end) do
        nil ->
          %{
            state
            | values: state.values ++ [%{pid: origin, ref: Process.monitor(origin), data: data}]
          }

        _ ->
          %{
            state
            | values: [%{Enum.find(state.values, fn map -> map.pid == origin end) | data: data}]
          }
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:send, state) do
    unless state.values === [] do
      Pecan.Router.send_frames(
        state.can_if,
        Pecan.create_frame(
          state.id,
          state.eff,
          false,
          false,
          8,
          :binary.encode_unsigned(
            Enum.reduce(state.values, 0, fn map, acc ->
              Bitwise.bor(:binary.decode_unsigned(map.data), acc)
            end)
          )
        )
      )
    end

    sched_send(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    {:noreply,
     case Enum.find(state.values, fn map -> map.ref == ref end) do
       nil -> state
       map -> %{state | values: state.values -- [map]}
     end}
  end

  defp sched_send(i) do
    Process.send_after(self(), :send, i)
  end
end
