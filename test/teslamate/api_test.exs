defmodule TeslaMate.ApiTest do
  use TeslaMate.DataCase

  alias TeslaMate.Api
  alias TeslaMate.Auth.{Tokens, Credentials}

  import Mock

  def start_api(name, opts \\ []) do
    auth_name = :"auth_#{name}"
    vehicles_name = :"vehicles_#{name}"

    start_auth? = !!Keyword.get(opts, :start_auth, true)

    if start_auth? do
      tokens = Keyword.get(opts, :tokens)
      {:ok, _pid} = start_supervised({AuthMock, name: auth_name, tokens: tokens, pid: self()})
    end

    {:ok, _pid} = start_supervised({VehiclesMock, name: vehicles_name, pid: self()})

    opts = [
      {:name, name},
      {:vehicles, {VehiclesMock, vehicles_name}}
      | if(start_auth?, do: [auth: {AuthMock, auth_name}], else: [])
    ]

    with {:ok, _} <- start_supervised({Api, opts}) do
      :ok
    end
  end

  defp vehicle_mock(pid) do
    {TeslaApi.Vehicle, [],
     [
       list: fn auth ->
         send(pid, {TeslaApi.Vehicle, {:list, auth}})
         {:ok, [%TeslaApi.Vehicle{}]}
       end,
       get: fn auth, id ->
         send(pid, {TeslaApi.Vehicle, {:get, auth, id}})
         {:ok, %TeslaApi.Vehicle{id: id}}
       end,
       get_with_state: fn auth, id ->
         send(pid, {TeslaApi.Vehicle, {:get_with_state, auth, id}})
         {:ok, %TeslaApi.Vehicle{id: id}}
       end
     ]}
  end

  defp auth_mock(pid) do
    {TeslaApi.Auth, [],
     [
       login: fn email, password ->
         send(pid, {TeslaApi.Auth, {:login, email, password}})
         {:ok, %TeslaApi.Auth{token: "$token", refresh_token: "$token", expires_in: 10_000_000}}
       end,
       refresh: fn
         %{token: nil, refresh_token: nil} = auth ->
           send(pid, {TeslaApi.Auth, {:refresh, auth}})
           {:error, %TeslaApi.Error{reason: :induced_error, message: "foo"}}

         auth ->
           send(pid, {TeslaApi.Auth, {:refresh, auth}})
           {:ok, %TeslaApi.Auth{token: "$token", refresh_token: "$token", expires_in: 10_000_000}}
       end
     ]}
  end

  @valid_tokens %Tokens{access: "$access", refresh: "$refresh"}
  @invalid_tokens %Tokens{access: nil, refresh: nil}
  @valid_credentials %Credentials{email: "teslamate", password: "foo"}

  describe "sign in" do
    test "starts without tokens ", %{test: name} do
      with_mocks [auth_mock(self()), vehicle_mock(self())] do
        :ok = start_api(name, tokens: nil)

        assert false == Api.signed_in?(name)
        assert {:error, :not_signed_in} = Api.list_vehicles(name)
        assert {:error, :not_signed_in} = Api.get_vehicle(name, 0)
        assert {:error, :not_signed_in} = Api.get_vehicle_with_state(name, 0)

        refute_receive _
      end
    end

    test "starts if tokens are valid", %{test: name} do
      with_mocks [auth_mock(self()), vehicle_mock(self())] do
        :ok = start_api(name, tokens: @valid_tokens)

        assert_receive {TeslaApi.Auth,
                        {:refresh, %TeslaApi.Auth{refresh_token: "$refresh", token: "$access"}}}

        assert_receive {AuthMock, {:save, %TeslaApi.Auth{}}}

        assert true == Api.signed_in?(name)

        refute_receive _
      end
    end

    @tag :capture_log
    test "starts anyway if tokens are invalid ", %{test: name} do
      with_mocks [auth_mock(self()), vehicle_mock(self())] do
        :ok = start_api(name, tokens: @invalid_tokens)

        assert_receive {TeslaApi.Auth, {:refresh, %TeslaApi.Auth{refresh_token: nil, token: nil}}}

        assert false == Api.signed_in?(name)

        refute_receive _
      end
    end
  end

  describe "sign_in/1" do
    test "allows delayed sign in", %{test: name} do
      with_mocks [auth_mock(self()), vehicle_mock(self())] do
        :ok = start_api(name, tokens: nil)

        assert false == Api.signed_in?(name)

        assert :ok = Api.sign_in(name, @valid_credentials)

        assert_receive {TeslaApi.Auth, {:login, "teslamate", "foo"}}
        assert_receive {AuthMock, {:save, %TeslaApi.Auth{}}}
        assert_receive {VehiclesMock, :restart}
        assert true == Api.signed_in?(name)

        refute_receive _
      end
    end

    test "fails if already signed in", %{test: name} do
      with_mocks [auth_mock(self()), vehicle_mock(self())] do
        :ok = start_api(name, tokens: @valid_tokens)

        assert_receive {TeslaApi.Auth, {:refresh, %TeslaApi.Auth{}}}
        assert_receive {AuthMock, {:save, %TeslaApi.Auth{}}}
        assert true == Api.signed_in?(name)

        assert {:error, :already_signed_in} = Api.sign_in(name, @valid_credentials)

        refute_receive _
      end
    end

    test "fails if api returns error", %{test: name} do
      login = fn _email, _password ->
        {:error, %TeslaApi.Error{reason: :unauthorized, env: %Finch.Response{}}}
      end

      with_mock TeslaApi.Auth, login: login do
        :ok = start_api(name, start_auth: false)
        assert {:error, :unauthorized} = Api.sign_in(name, @valid_credentials)
      end
    end
  end

  describe "refresh" do
    test "refreshes tokens", %{test: name} do
      with_mocks [auth_mock(self()), vehicle_mock(self())] do
        :ok = start_api(name, tokens: @valid_tokens)

        assert_receive {TeslaApi.Auth, {:refresh, %TeslaApi.Auth{}}}
        assert_receive {AuthMock, {:save, %TeslaApi.Auth{}}}
        assert true == Api.signed_in?(name)

        send(name, :refresh_auth)

        assert_receive {TeslaApi.Auth, {:refresh, %TeslaApi.Auth{}}}
        assert_receive {AuthMock, {:save, %TeslaApi.Auth{}}}

        refute_receive _
      end
    end
  end

  describe "Vehicle API" do
    test "get_vehicle/1", %{test: name} do
      with_mocks [auth_mock(self()), vehicle_mock(self())] do
        :ok = start_api(name, tokens: @valid_tokens)
        assert_receive {TeslaApi.Auth, {:refresh, _}}
        assert_receive {AuthMock, {:save, %TeslaApi.Auth{}}}

        assert {:ok, %TeslaApi.Vehicle{id: 0}} = Api.get_vehicle(name, 0)
        assert_receive {TeslaApi.Vehicle, {:get, %TeslaApi.Auth{}, 0}}

        refute_receive _
      end
    end

    test "get_vehicle_with_state/1", %{test: name} do
      with_mocks [auth_mock(self()), vehicle_mock(self())] do
        :ok = start_api(name, tokens: @valid_tokens)
        assert_receive {TeslaApi.Auth, {:refresh, _}}
        assert_receive {AuthMock, {:save, %TeslaApi.Auth{}}}

        assert {:ok, %TeslaApi.Vehicle{id: 0}} = Api.get_vehicle_with_state(name, 0)
        assert_receive {TeslaApi.Vehicle, {:get_with_state, %TeslaApi.Auth{}, 0}}

        refute_receive _
      end
    end

    test "list_vehicles/0", %{test: name} do
      with_mocks [auth_mock(self()), vehicle_mock(self())] do
        :ok = start_api(name, tokens: @valid_tokens)
        assert_receive {TeslaApi.Auth, {:refresh, _}}
        assert_receive {AuthMock, {:save, %TeslaApi.Auth{}}}

        assert {:ok, [%TeslaApi.Vehicle{}]} = Api.list_vehicles(name)
        assert_receive {TeslaApi.Vehicle, {:list, %TeslaApi.Auth{}}}

        refute_receive _
      end
    end

    test ":not_signed_in", %{test: name} do
      vehicle_mock =
        {TeslaApi.Vehicle, [],
         [
           list: fn _ ->
             {:error, %TeslaApi.Error{reason: :unauthorized, env: %Finch.Response{}}}
           end,
           get: fn _, _ ->
             {:error, %TeslaApi.Error{reason: :unauthorized, env: %Finch.Response{}}}
           end,
           get_with_state: fn _, _ ->
             {:error, %TeslaApi.Error{reason: :unauthorized, env: %Finch.Response{}}}
           end
         ]}

      with_mocks [auth_mock(self()), vehicle_mock] do
        :ok = start_api(name, start_auth: false)

        assert :ok = Api.sign_in(name, @valid_credentials)
        assert {:error, :not_signed_in} = Api.list_vehicles(name)

        assert :ok = Api.sign_in(name, @valid_credentials)
        assert {:error, :not_signed_in} = Api.get_vehicle(name, 0)

        assert :ok = Api.sign_in(name, @valid_credentials)
        assert {:error, :not_signed_in} = Api.get_vehicle_with_state(name, 0)
      end
    end

    test "returns :not_signed_in if Api GenServer is not found", %{test: name} do
      assert {:error, :not_signed_in} = Api.list_vehicles(name)
    end

    test "handles unknown messages gracefully", %{test: name} do
      vehicle_mock =
        {TeslaApi.Vehicle, [],
         [
           list: fn _ ->
             {:error, %TeslaApi.Error{reason: :unauthorized, env: %Finch.Response{}}}
           end,
           get: fn _, _ ->
             {:error, %TeslaApi.Error{reason: :unauthorized, env: %Finch.Response{}}}
           end,
           get_with_state: fn _, _ ->
             {:error, %TeslaApi.Error{reason: :unauthorized, env: %Finch.Response{}}}
           end
         ]}

      with_mocks [auth_mock(self()), vehicle_mock] do
        :ok = start_api(name, start_auth: false)

        true =
          name
          |> Process.whereis()
          |> Process.link()

        send(name, :boom)

        refute_receive _
      end
    end

    @tag :capture_log
    test ":vehicle_not_found", %{test: name} do
      api_error = %TeslaApi.Error{reason: :vehicle_not_found, env: %Finch.Response{}}

      vehicle_mock =
        {TeslaApi.Vehicle, [],
         [
           get: fn _auth, _id -> {:error, api_error} end,
           get_with_state: fn _auth, _id -> {:error, api_error} end
         ]}

      with_mocks [auth_mock(self()), vehicle_mock] do
        :ok = start_api(name, start_auth: false)

        assert :ok = Api.sign_in(name, @valid_credentials)
        assert {:error, :vehicle_not_found} = Api.get_vehicle(name, 0)
        assert {:error, :vehicle_not_found} = Api.get_vehicle_with_state(name, 0)
      end
    end

    @tag :capture_log
    test "other error witn Env", %{test: name} do
      api_error = %TeslaApi.Error{
        reason: :unknown,
        message: "",
        env: %Finch.Response{status: 503, body: ""}
      }

      vehicle_mock =
        {TeslaApi.Vehicle, [],
         [
           list: fn _auth -> {:error, api_error} end,
           get: fn _auth, _id -> {:error, api_error} end,
           get_with_state: fn _auth, _id -> {:error, api_error} end
         ]}

      with_mocks [auth_mock(self()), vehicle_mock] do
        :ok = start_api(name, start_auth: false)

        assert :ok = Api.sign_in(name, @valid_credentials)
        assert {:error, :unknown} = Api.list_vehicles(name)
        assert {:error, :unknown} = Api.get_vehicle(name, 0)
        assert {:error, :unknown} = Api.get_vehicle_with_state(name, 0)
      end
    end

    @tag :capture_log
    test "other error witnout Env", %{test: name} do
      api_error = %TeslaApi.Error{reason: :closed, message: "foo"}

      vehicle_mock =
        {TeslaApi.Vehicle, [],
         [
           list: fn _auth -> {:error, api_error} end,
           get: fn _auth, _id -> {:error, api_error} end,
           get_with_state: fn _auth, _id -> {:error, api_error} end
         ]}

      with_mocks [auth_mock(self()), vehicle_mock] do
        :ok = start_api(name, start_auth: false)

        assert :ok = Api.sign_in(name, @valid_credentials)
        assert {:error, :closed} = Api.list_vehicles(name)
        assert {:error, :closed} = Api.get_vehicle(name, 0)
        assert {:error, :closed} = Api.get_vehicle_with_state(name, 0)
      end
    end
  end
end
