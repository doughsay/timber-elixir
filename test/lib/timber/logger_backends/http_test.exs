defmodule Timber.LoggerBackends.HTTPTest do
  use Timber.TestCase

  alias Timber.FakeHTTPClient
  alias Timber.LogEntry
  alias Timber.LoggerBackends.HTTP

  describe "Timber.LoggerBackends.HTTP.init/1" do
    test "configures properly" do
      FakeHTTPClient.stub :request, fn :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
        {:ok, 204, %{}, ""}
      end

      {:ok, state} = HTTP.init(HTTP)
      assert state.api_key == "api_key"
    end

    test "starts the flusher" do
      FakeHTTPClient.stub :request, fn :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
          {:ok, 204, %{}, ""}
      end

      HTTP.init(HTTP)
      assert_receive(:outlet, 1100)
    end
  end

  describe "Timber.LoggerBackends.HTTP.handle_call/2" do
    test "{:configure, options} message raises when the API key is inil" do
      FakeHTTPClient.stub :request, fn :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
          {:ok, 204, %{}, ""}
      end

      {:ok, state} = HTTP.init(HTTP)

      assert_raise Timber.LoggerBackends.HTTP.NoTimberAPIKeyError, fn ->
        HTTP.handle_call({:configure, [api_key: nil]}, state)
      end
    end

    test "{:configure, options} message raises when the API key is invalid" do
      FakeHTTPClient.stub :request, fn
        :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
          {:ok, 204, %{}, ""}
        :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic aW52YWxpZA=="}, _ ->
          {:ok, 401, %{}, ""}
      end

      {:ok, state} = HTTP.init(HTTP)

      assert_raise Timber.LoggerBackends.HTTP.TimberAPIKeyInvalid, fn ->
        HTTP.handle_call({:configure, [api_key: "invalid"]}, state)
      end
    end

    test "{:configure, options} message updates the api key" do
      FakeHTTPClient.stub :request, fn
        :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic bmV3X2FwaV9rZXk="}, _ ->
          {:ok, 204, %{}, ""}
        :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
          {:ok, 204, %{}, ""}
      end

      {:ok, state} = HTTP.init(HTTP)
      {:ok, :ok, new_state} = HTTP.handle_call({:configure, [api_key: "new_api_key"]}, state)
      assert new_state.api_key == "new_api_key"
    end

    test "{:configure, options} message updates the max_buffer_size" do
      FakeHTTPClient.stub :request, fn :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
          {:ok, 204, %{}, ""}
      end

      {:ok, state} = HTTP.init(HTTP)
      {:ok, :ok, new_state} = HTTP.handle_call({:configure, [max_buffer_size: 100]}, state)
      assert new_state.max_buffer_size == 100
    end
  end

  describe "Timber.LoggerBackends.HTTP.handle_event/2" do
    test ":flush message raises without an api key" do
      FakeHTTPClient.stub :request, fn :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
          {:ok, 204, %{}, ""}
      end

      entry = {:info, self, {Logger, "message", time(), [event: %{type: :type, data: %{}}]}}
      {:ok, state} = HTTP.init(HTTP)
      {:ok, :ok, state} = HTTP.handle_call({:configure, [api_key: "api_key"]}, state)
      {:ok, state} = HTTP.handle_event(entry, state)
      state = %{ state | api_key: nil }
      assert_raise Timber.LoggerBackends.HTTP.NoTimberAPIKeyError, fn ->
        HTTP.handle_event(:flush, state)
      end
    end

    test ":flush message issues a request" do
      FakeHTTPClient.stub :request, fn :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
        {:ok, 204, %{}, ""}
      end

      entry = {:info, self, {Logger, "message", time(), [event: %{type: :type, data: %{}}]}}
      {:ok, state} = HTTP.init(HTTP)
      {:ok, state} = HTTP.handle_event(entry, state)
      HTTP.handle_event(:flush, state)

      calls = FakeHTTPClient.get_async_request_calls()
      assert length(calls) == 1

      call = Enum.at(calls, 0)
      assert elem(call, 0) == :post
      assert elem(call, 1) == "https://logs.timber.io/frames"

      vsn = Application.spec(:timber, :vsn)
      assert elem(call, 2) == %{"Authorization" => "Basic YXBpX2tleQ==", "Content-Type" => "application/msgpack", "User-Agent" => "Timber Elixir/#{vsn} (HTTP)"}

      encoded_body = event_entry_to_msgpack(entry)
      assert elem(call, 3) == encoded_body
    end

    test ":flush message issues a request with chardata" do
      FakeHTTPClient.stub :request, fn :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
        {:ok, 204, %{}, ""}
      end

      entry = {:info, self, {Logger, "message", time(), [event: %{type: :type, data: %{}}]}}
      {:ok, state} = HTTP.init(HTTP)
      {:ok, state} = HTTP.handle_event(entry, state)
      HTTP.handle_event(:flush, state)

      calls = FakeHTTPClient.get_async_request_calls()
      assert length(calls) == 1

      call = Enum.at(calls, 0)
      encoded_body = event_entry_to_msgpack(entry)
      assert elem(call, 3) == encoded_body
    end

    test "failure of the http client will not cause the :flush message to raise" do
      FakeHTTPClient.stub :request, fn :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
        {:ok, 204, %{}, ""}
      end

      entry = {:info, self, {Logger, "message", time(), [event: %{type: :type, data: %{}}]}}

      expected_method = :post
      expected_url = "https://logs.timber.io/frames"
      vsn = Application.spec(:timber, :vsn)
      expected_headers = %{"Authorization" => "Basic YXBpX2tleQ==",
        "Content-Type" => "application/msgpack", "User-Agent" => "Timber Elixir/#{vsn} (HTTP)"}

      expected_body = event_entry_to_msgpack(entry)

      FakeHTTPClient.stub :async_request, fn ^expected_method, ^expected_url, ^expected_headers, ^expected_body ->
        {:error, :connect_timeout}
      end

      {:ok, state} = HTTP.init(HTTP)
      {:ok, state} = HTTP.handle_event(entry, state)
      {:ok, _} = HTTP.handle_event(:flush, state)
    end

    test "message event buffers the message if the buffer is not full" do
      FakeHTTPClient.stub :request, fn :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
          {:ok, 204, %{}, ""}
      end

      entry = {:info, self, {Logger, "message", time(), [event: %{type: :type, data: %{}}]}}

      {:ok, state} = HTTP.init(HTTP)
      {:ok, new_state} = HTTP.handle_event(entry, state)
      assert new_state.buffer == [event_entry_to_log_entry(entry)]
      calls = FakeHTTPClient.get_async_request_calls()
      assert length(calls) == 0
    end

    test "flushes if the buffer is full" do
      FakeHTTPClient.stub :request, fn :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
        {:ok, 204, %{}, ""}
      end

      entry = {:info, self, {Logger, "message", time(), [event: %{type: :type, data: %{}}]}}
      {:ok, state} = HTTP.init(HTTP)
      state = %{state | max_buffer_size: 1}
      HTTP.handle_event(entry, state)
      calls = FakeHTTPClient.get_async_request_calls()
      assert length(calls) == 1
    end
  end

  describe "Timber.LoggerBackends.HTTP.handle_info/2" do
    test "handles the outlet properly" do
      FakeHTTPClient.stub :request, fn :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
        {:ok, 204, %{}, ""}
      end

      entry = {:info, self, {Logger, "message", time(), [event: %{type: :type, data: %{}}]}}
      {:ok, state} = HTTP.init(HTTP)
      {:ok, state} = HTTP.handle_event(entry, state)
      {:ok, new_state} = HTTP.handle_info(:outlet, state)
      calls = FakeHTTPClient.get_async_request_calls()
      assert length(calls) == 1
      assert length(new_state.buffer) == 0
      assert_receive(:outlet, 1100)
    end

    test "ignores everything else" do
      FakeHTTPClient.stub :request, fn :get, "https://api.timber.io/installer/application", %{"Authorization" => "Basic YXBpX2tleQ=="}, _ ->
        {:ok, 204, %{}, ""}
      end

      {:ok, state} = HTTP.init(HTTP)
      {:ok, new_state} = HTTP.handle_info(:unknown, state)
      assert state == new_state
    end
  end

  defp time do
    {{2016, 1, 21}, {12, 54, 56, {1234, 4}}}
  end

  defp event_entry_to_log_entry({level, _, {Logger, message, ts, metadata}}) do
    LogEntry.new(ts, level, message, metadata)
  end

  defp event_entry_to_msgpack(entry) do
    log_entry = event_entry_to_log_entry(entry)
    map =
      log_entry
      |> LogEntry.to_map!()
      |> Map.put(:message, IO.chardata_to_string(log_entry.message))

    Msgpax.pack!([map])
  end
end
