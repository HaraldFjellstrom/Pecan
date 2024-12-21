defmodule Pecan.Router do
  use GenServer

  # Notes for docs
  # Regex match nothing ~r'$^'
  # Regex match everything ~r'(.*?)'
  # Shared Send fixed DLC to 8

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def open(if_name) do
    GenServer.call(__MODULE__, {:open, if_name})
  end

  def close(if_name) do
    GenServer.call(__MODULE__, {:close, if_name})
  end

  def avalible do
    GenServer.call(__MODULE__, :avalible)
  end

  def send_frames(if_name, frames) do
    GenServer.call(__MODULE__, {:send, if_name, if(is_list(frames), do: frames, else: [frames])})
  end

  def shared_send(if_name, interval, frame, force \\ false) do
    GenServer.call(__MODULE__, {:shared_send, if_name, interval, frame, force})
  end

  def attach(if_name \\ nil, std_filter \\ {:regex, ~r'(.*?)'}, ext_filter \\ {:regex, ~r'(.*?)'}) do
    GenServer.call(__MODULE__, {:attach, if_name, std_filter, ext_filter})
  end

  def detach(if_name \\ nil) do
    GenServer.call(__MODULE__, {:detach, if_name})
  end

  @impl true
  def init(_args) do
    state =
      Enum.map(DynamicSupervisor.which_children(Pecan.SocketSupervisor), fn map ->
        {_, pid, _, _} = map
        %{socket_pid: pid, interface_name: Pecan.Socket.get_name(pid), subscribers: []}
      end)

    {:ok, state}
  end

  @impl true
  def handle_call(:avalible, _from, state) do
    list = Enum.reduce(state, [], fn e, acc -> acc ++ [e.interface_name] end)
    {:reply, list, state}
  end

  @impl true
  def handle_call({:open, if_name}, _from, state) do
    if :os.cmd(to_charlist("ip link | grep -w #{if_name}")) === [] do
      {:reply, {:error, "socket not found"}, state}
    else
      if Enum.find(state, fn map -> map[:interface_name] == if_name end) === nil do
        {to_sender, state} = start_socket(if_name, state)
        {:reply, to_sender, state}
      else
        {:reply, {:noop, "socket already in use"}, state}
      end
    end
  end

  @impl true
  def handle_call({:close, if_name}, _from, state) do
    socket = Enum.find(state, fn map -> map.interface_name == if_name end)
    pid = socket.socket_pid
    state = state -- [socket]

    DynamicSupervisor.terminate_child(
      Pecan.SocketSupervisor,
      pid
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:attach, if_name, std_filter, ext_filter}, from, state) do
    {pid, _} = from

    new_state =
      Enum.map(state, fn map ->
        if map.interface_name === if_name or is_nil(if_name),
          do: %{map | :subscribers => map.subscribers ++ [{pid, std_filter, ext_filter}]}
      end)

    {:reply, unless(state === new_state, do: :ok, else: :noop), new_state}
  end

  @impl true
  def handle_call({:detach, if_name}, from, state) do
    {pid, _} = from

    new_state =
      Enum.map(state, fn map ->
        if map.interface_name === if_name or is_nil(if_name),
          do: %{
            map
            | :subscribers =>
                map.subscribers --
                  Enum.filter(map.subscribers, fn {lf_pid, _, _} -> lf_pid in [pid] end)
          }
      end)

    {:reply, unless(state === new_state, do: :ok, else: :noop), new_state}
  end

  @impl true
  def handle_call({:send, if_name, frames}, _from, state) when is_binary(if_name) do
    {:reply,
     Pecan.Socket.send(
       Enum.find(state, fn map -> map.interface_name == if_name end).socket_pid,
       frames
     ), state}
  end

  @impl true
  def handle_call({:shared_send, if_name, interval, frame, force}, from, state)
      when is_binary(if_name) do
    shared_atom = String.to_atom(if(frame.eff, do: "e", else: "s") <> to_string(frame.id))

    if Process.whereis(shared_atom) === nil do
      DynamicSupervisor.start_child(
        Pecan.SharedSendSupervisor,
        {Pecan.Router.SharedSend, [name: shared_atom, interval: interval, can_if: if_name]}
      )

      :erlang.yield()
    end

    {from_pid, _} = from
    shared_sender_pid = Pecan.Router.SharedSend.add_value(shared_atom, from_pid, frame.data)

    if force do
      :erlang.yield()
      Pecan.Router.SharedSend.force_send(shared_atom)
    end

    {:reply, shared_sender_pid, state}
  end

  @impl true
  def handle_info({:fetch, if_name}, state) do
    route_msges(Enum.find(state, fn sock -> sock[:interface_name] == if_name end))
    #Enum.map(state, fn map -> route_msges(map) end)
    {:noreply, state}
  end

  defp route_msges(sock) do
    msges = Pecan.Socket.fetch(sock.socket_pid)

    Enum.map(msges, fn msg ->
      Enum.map(sock.subscribers, fn {sub, std_filter, ext_filter} ->
        case {if(msg.eff == 1, do: ext_filter, else: std_filter), msg.id} do
          {{:fun, filter}, val} ->
            if filter.(val), do: send(sub, {:can_frame, msg})

          {{:regex, filter}, val} ->
            if Regex.match?(filter, to_string(val)), do: send(sub, {:can_frame, msg})

          _ ->
            false
        end
      end)
    end)
  end

  defp start_socket(if_name, state) do
    {to_sender, pid} =
      DynamicSupervisor.start_child(Pecan.SocketSupervisor, {Pecan.Socket, if_name})

    state = state ++ [%{socket_pid: pid, interface_name: if_name, subscribers: []}]
    {to_sender, state}
  end
end
