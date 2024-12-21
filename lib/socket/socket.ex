defmodule Pecan.Socket do
  require Logger
  use GenServer

  @canmsgsize 128
  @af_can 29
  @can_raw 1

  defstruct [:socket, :if_name, :read_buff, :send_buff, :send_chunk]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def fetch(pid) do
    GenServer.call(pid, :fetch)
  end

  def send(pid, frames) do
    GenServer.cast(pid, {:send, frames})
  end

  def get_name(pid) do
    GenServer.call(pid, :get_name)
  end

  @impl true
  def init(if_name) do
    {:ok, socket} = :socket.open(@af_can, :raw, @can_raw)
    {:ok, ifindex} = :socket.ioctl(socket, :gifindex, to_charlist(if_name))
    addr = <<0::size(16)-little, ifindex::size(32)-little, 0::size(32), 0::size(32), 0::size(64)>>
    :socket.bind(socket, %{:family => @af_can, :addr => addr})

    bitrate =
      :os.cmd(to_charlist("ip -det link show #{if_name} | grep bitrate | awk '{print $2}'"))

    bitrate =
      case Enum.any?(bitrate) do
        true ->
          Integer.parse(hd(bitrate)) |> elem(0)

        false ->
          500_000
      end

    Logger.info("Opening socket #{if_name}, bitrate set to #{inspect(bitrate)}")
    Process.send_after(self(), {:"$socket", "start", :select, "start"}, 100)

    {:ok,
     %Pecan.Socket{
       socket: socket,
       if_name: if_name,
       read_buff: [],
       send_buff: [],
       send_chunk: trunc(bitrate / @canmsgsize / 1000)
     }}
  end

  @impl true
  def handle_cast({:send, frames}, state) do
    state = %Pecan.Socket{state | :send_buff => frames ++ state.send_buff}
    sched_snd_frames()
    {:noreply, state}
  end

  @impl true
  def handle_call(:fetch, _from, state) do
    taken = Enum.reverse(state.read_buff)
    state = %Pecan.Socket{state | read_buff: []}
    {:reply, taken, state}
  end

  @impl true
  def handle_call(:get_name, _from, state) do
    {:reply, state.if_name, state}
  end

  @impl true
  def handle_info({:"$socket", _, :select, _}, state) do
    state = rcv_loop(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:snd, state) do
    state = snd_loop(state)
    {:noreply, state}
  end

  defp snd_loop(state) do
    {new_send_buff, to_be_sent} = Enum.split(state.send_buff, -4)
    to_be_sent = Enum.reverse(to_be_sent)
    Enum.map(to_be_sent, fn x -> send_single(state.socket, x) end)

    unless new_send_buff == [], do: sched_snd_frames()

    %Pecan.Socket{
      state
      | :send_buff => new_send_buff
    }
  end

  defp send_single(socket, frame) do
    :socket.send(
      socket,
      if(is_struct(frame, Pecan.CanFrame), do: Pecan.binary_from_frame(frame), else: frame)
    )
  end

  defp rcv_loop(state) do
    case :socket.recv(state.socket, 0, [], :nowait) do
      {:ok, frm} ->
        state = %Pecan.Socket{
          state
          | :read_buff => [Pecan.frame_from_binary(frm) | state.read_buff]
        }

        rcv_loop(state)

      {:select, _} ->
        Process.send(Pecan.Router, {:fetch, state.if_name}, [])
        state

      {:error, info} ->
        Logger.error(inspect(info))
        state
    end
  end

  defp sched_snd_frames do
    Process.send_after(self(), :snd, 1)
  end
end
