defmodule PecanTest do
  use ExUnit.Case
  doctest Pecan

  test "greets the world" do
    assert Pecan.hello() == :world
  end
end
