defmodule Pecan do

@moduledoc """
### a tasty nut or *Pure Elixir CAN*

>#### NOTE {: .info}
>This library uses [Socket CAN](https://docs.kernel.org/networking/can.html) and is thus only usable
>on Linux, aimed at usage on *[Nerves](https://nerves-project.org/)* systems.

### Process structure

Pecan spawns three processes when started,

  * `Pecan.Router` - Responsible of handeling the routing off messages and
  keeping the state of sockets.

  * `Pecan.SocketSupervisor` - `DynamicSupervisor` that all `Pecan.Socket` are
  children of.

  * `Pecan.SharedSendSupervisor` - `DynamicSupervisor` that all
  `Pecan.SharedSend` are children of.

The general idea is to use functions exposed thouth the `Pecan.Router` to send
and recive CAN messages. The user can open and close sockets, subscribe to
messages based on socket and id. Sending messages is done by passing it to the
`Pecan.Socket` send buffer to be sent as quick as the buss allows. Using the
`Pecan.SharedSend` process is necessary if you want multiple processes tho be
able to update the data of a message.

The process structure is designed to be self healing, but some addaptations
needs to be done by a user. More about this can be found under
`Pecan.Router.attach/3` and `Pecan.Router.shared_send/4`.

### This module contains

`Pecan.CanFrame` a user friendly struct reprecentation of a CAN frame and some
helper functions for transforming binary to `Pecan.CanFrame` or the other way
around.

"""

defmodule CanFrame do
  defstruct [:id, :eff, :rtr, :err, :dlc, :data]
end

@doc """
Create valid `Pecan.CanFrame` struct

## Examples

    iex> Pecan.create_frame(25, true, <<0, 1, 2, 3>>)
    %Pecan.CanFrame{id: 25, eff: 1, rtr: 0, err: 0, dlc: 4, data: <<0, 1, 2, 3>>}

"""
  def create_frame(
        id,
        extended \\ false,
        remote_request \\ false,
        error_frame \\ false,
        fixed_dlc \\ nil,
        data
      ) do
    if extended do
      if ceil(:math.log2(id)) > 29,
        do: raise(ArgumentError, message: "invalid extended identifier")
    else
      if ceil(:math.log2(id)) > 11,
        do: raise(ArgumentError, message: "invalid standard identifier")
    end

    unless is_binary(data), do: raise(ArgumentError, message: "data needs to be binary")

    if byte_size(data) > 8,
      do: raise(ArgumentError, message: "data exceeds the size limit of 8 bytes")

    %CanFrame{
      id: id,
      eff: if(extended, do: 1, else: 0),
      rtr: if(remote_request, do: 1, else: 0),
      err: if(error_frame, do: 1, else: 0),
      dlc: if(fixed_dlc == nil, do: byte_size(data), else: fixed_dlc),
      data: <<data::binary, 0::(8-byte_size(data))*8>>
    }
  end

@doc """
Binary data from `Pecan.CanFrame` struct
Used to convert struct to binary to send over socket can

## Examples

    iex> Pecan.binary_from_frame( Pecan.create_frame(25, true, <<0, 1, 2, 3>>) )
    <<25, 0, 0, 128, 4, 0, 0, 0, 0, 1, 2, 3>>

"""
  def binary_from_frame(can_frame) do
    <<id::unsigned-integer-size(32)>> =
      <<can_frame.eff::size(1), can_frame.rtr::size(1), can_frame.err::size(1),
        can_frame.id::size(29)>>

    <<id::size(32)-little, can_frame.dlc::size(8), 0::size(24), can_frame.data::binary>>
  end

@doc """
Parse binary data from socket can to `Pecan.CanFrame` struct

## Examples

    iex> Pecan.frame_from_binary(<<25, 0, 0, 128, 4, 0, 0, 0, 0, 1, 2, 3>>)
    %Pecan.CanFrame{id: 25, eff: 1, rtr: 0, err: 0, dlc: 4, data: <<0, 1, 2, 3>>}

"""
  def frame_from_binary(binary) do
    <<header::size(32)-little, dlc::size(8), _padding::size(24), data::binary>> = binary
    <<eff::size(1), rtr::size(1), err::size(1), id::size(29)>> = <<header::size(32)>>

    %CanFrame{
      id: id,
      eff: eff,
      rtr: rtr,
      err: err,
      dlc: dlc,
      data: data
    }
  end
end
