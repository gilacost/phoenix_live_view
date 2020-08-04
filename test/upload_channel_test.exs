defmodule Phoenix.LiveView.UploadChannelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.ChannelTest

  alias Phoenix.LiveView

  @endpoint Phoenix.LiveViewTest.Endpoint

  def inspect_html_safe(term) do
    term
    |> inspect()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  def valid_token(lv_pid, ref) do
    LiveView.Static.sign_token(@endpoint, %{pid: lv_pid, ref: ref})
  end

  def mount_lv(setup) when is_function(setup, 1) do
    conn = Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})
    {:ok, lv, _} = live_isolated(conn, Phoenix.LiveViewTest.UploadLive, session: %{})
    :ok = GenServer.call(lv.pid, {:run, setup})
    {:ok, lv}
  end

  def join_upload_channel(socket, lv, selector, entries) do
    case render_upload(element(lv, selector), entries) do
      %{error: reason} ->
        {:error, reason}

      %{entries: entries} ->
        for {_ref, token} <- entries,
            do: subscribe_and_join(socket, "lvu:123", %{"token" => token})
    end
  end

  defp build_entries(count) do
    for i <- 1..count do
      %{
        "last_modified" => 1_594_171_879_000,
        "name" => "myfile#{i}",
        "size" => 1_396_009,
        "type" => "image/jpeg",
        "ref" => i
      }
    end
  end

  setup_all do
    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, _} = @endpoint.start_link()

      {:ok, _} =
        Supervisor.start_link([Phoenix.PubSub.child_spec(name: Phoenix.LiveView.PubSub)],
          strategy: :one_for_one
        )
    end)

    :ok
  end

  setup do
    {:ok, socket} = connect(LiveView.Socket, %{}, %{})
    {:ok, socket: socket}
  end

  test "rejects invalid token", %{socket: socket} do
    assert {:error, %{reason: "invalid_token"}} =
             subscribe_and_join(socket, "lvu:123", %{"token" => "bad"})
  end

  describe "with valid token" do
    setup %{allow: opts} do
      {:ok, lv} = mount_lv(fn socket -> Phoenix.LiveView.allow_upload(socket, :avatar, opts) end)
      {:ok, lv: lv}
    end

    @tag allow: [accept: :any]
    test "returns client configuration", %{socket: socket, lv: lv} do
      assert [{:ok, %{}, socket}] =
               join_upload_channel(socket, lv, "input[name=avatar]", build_entries(1))
    end

    @tag allow: [accept: :any]
    test "upload channel exits when LiveView channel exits", %{socket: socket, lv: lv} do
      assert [{:ok, _, socket}] =
               join_upload_channel(socket, lv, "input[name=avatar]", build_entries(1))

      channel_pid = socket.channel_pid
      Process.unlink(proxy_pid(lv))
      Process.unlink(channel_pid)
      Process.monitor(channel_pid)
      Process.exit(lv.pid, :kill)
      assert_receive {:DOWN, _ref, :process, ^channel_pid, :killed}
    end

    @tag allow: [accept: :any]
    test "abnormal channel exit brings down LiveView", %{socket: socket, lv: lv} do
      assert [{:ok, _, socket}] =
               join_upload_channel(socket, lv, "input[name=avatar]", build_entries(1))

      channel_pid = socket.channel_pid
      lv_pid = lv.pid
      Process.unlink(proxy_pid(lv))
      Process.unlink(channel_pid)
      Process.monitor(lv_pid)
      Process.exit(channel_pid, :kill)
      assert_receive {:DOWN, _ref, :process, ^lv_pid, {:shutdown, {:channel_upload_exit, :killed}}}
    end

    @tag allow: [accept: :any]
    test "normal channel exit is cleaned up by LiveView", %{socket: socket, lv: lv} do
      assert [{:ok, _, socket}] =
               join_upload_channel(socket, lv, "input[name=avatar]", build_entries(1))

      channel_pid = socket.channel_pid
      lv_pid = lv.pid
      Process.unlink(proxy_pid(lv))
      Process.unlink(channel_pid)
      Process.monitor(lv_pid)
      assert render(lv) =~ "channel:#{inspect_html_safe(channel_pid)}"
      GenServer.stop(channel_pid, :normal)
      refute_receive {:DOWN, _ref, :process, ^lv_pid, _}
      assert render(lv) =~ "channel:nil"
    end


    @tag allow: [max_entries: 3, accept: :any]
    test "multiple entries under max", %{socket: socket, lv: lv} do
      assert [{:ok, _, socket1}, {:ok, _, socket2}] =
               join_upload_channel(socket, lv, "input[name=avatar]", build_entries(2))
      assert render(lv) =~ "channel:#{inspect_html_safe(socket1.channel_pid)}"
      assert render(lv) =~ "channel:#{inspect_html_safe(socket2.channel_pid)}"
    end

    @tag allow: [max_entries: 1, accept: :any]
    test "too many entries over max", %{socket: socket, lv: lv} do
      assert {:error, [_ref, :too_many_files]} =
               join_upload_channel(socket, lv, "input[name=avatar]", build_entries(2))
    end

    @tag allow: [max_entries: 3, accept: :any]
    test "starting an already in progress entry is denied", %{socket: socket, lv: lv} do
      assert [{:ok, _, socket1}] =
               join_upload_channel(socket, lv, "input[name=avatar]", build_entries(1))

      assert render(lv) =~ "channel:#{inspect_html_safe(socket1.channel_pid)}"
      assert {:error, [_ref, :already_started]} =
               join_upload_channel(socket, lv, "input[name=avatar]", build_entries(1))

      assert render(lv) =~ "channel:#{inspect_html_safe(socket1.channel_pid)}"
    end
  end
end