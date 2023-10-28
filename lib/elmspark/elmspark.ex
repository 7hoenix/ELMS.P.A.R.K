defmodule Elmspark.Elmspark do
  alias __MODULE__.EllmProgram
  alias ElmSpark.LLM
  alias Elmspark.Elmspark.ElmMakeServer
  alias Elmspark.Elmspark.EllmProgram
  alias Elmspark.Elmspark.Blueprint
  alias Elmspark.Elmspark.Events
  alias Elmspark.Repo

  require Logger

  def attempt_with_many(value, fun_with_retry_list) when is_list(fun_with_retry_list) do
    do_attempt_with_many(value, fun_with_retry_list, 0)
  end

  defp do_attempt_with_many(value, [], _attempt) do
    {:ok, value}
  end

  defp do_attempt_with_many(_value, [{fun, _max_retries} = head | _rest], attempt)
       when attempt > _max_retries do
    {:error, {:max_retries_reached, fun}}
  end

  defp do_attempt_with_many(value, [{fun, max_retries} | rest], attempt)
       when attempt <= max_retries do
    case fun.(value) do
      {:ok, result} ->
        do_attempt_with_many(result, rest, 0)

      {:error, _} ->
        do_attempt_with_many(value, [{fun, max_retries} | rest], attempt + 1)
    end
  end

  def gen_app(blueprint) do
    attempt_with_many(blueprint, [
      # 3 retries for gen_model
      {&gen_model/1, 0},
      # 2 retries for gen_init
      {&gen_init/1, 0},
      # 5 retries for gen_msg
      {&gen_msg/1, 0},
      # 3 retries for gen_update
      {&gen_update/1, 0},
      # 2 retries for gen_view
      {&gen_view/1, 0},
      # 1 retry for gen_js
      {&gen_js/1, 0}
    ])
  end

  def gen_model(blueprint) do
    EllmProgram.new()
    |> EllmProgram.set_stage(:add_model_alias)
    |> fetch_fields_from_llm(blueprint)
    |> convert_fields_to_elm_type_alias()
    |> compile_elm_program()
  end

  def gen_init(ellm_program) do
    ellm_program
    |> EllmProgram.set_stage(:add_init_function)
    |> fetch_init_from_llm()
    |> compile_elm_program()
  end

  def gen_msg(ellm_program) do
    ellm_program
    |> EllmProgram.set_stage(:add_messages)
    |> fetch_messages_from_llm()
    |> compile_elm_program()
  end

  def gen_update(ellm_program) do
    ellm_program
    |> EllmProgram.set_stage(:add_update_function)
    |> fetch_update_from_llm()
    |> compile_elm_program()
  end

  def gen_view(ellm_program) do
    ellm_program
    |> EllmProgram.set_stage(:add_view_function)
    |> fetch_view_from_llm()
    |> compile_elm_program()
  end

  def gen_js(ellm_program) do
    with {:ok, program} <-
           ellm_program
           |> compile_elm_program(output: "js") do
      main_file = File.read!("main.js")
      File.rm!("main.js")
      random_file_name = "main.js"
      path = Path.expand("./assets/js/main.js")
      File.write!(path, main_file)
      {:ok, program}
    else
      _ ->
        {:error, "Could not compile Elm to JS"}
    end
  end

  def get_blueprint(id), do: Repo.get(Blueprint, id)

  def create_blueprint(attrs) do
    %Blueprint{}
    |> Blueprint.changeset(attrs)
    |> Repo.insert()
  end

  def change_blueprint(blueprint, attrs) do
    blueprint
    |> Blueprint.changeset(attrs)
  end

  defp fetch_fields_from_llm(%EllmProgram{} = ellm_program, blueprint) do
    msg = generate(blueprint, &LLM.user_message/1)
    res = LLM.chat_completions([msg])

    case res do
      {:ok, %{choices: [%{message: %{content: fields}}]}} ->
        %{ellm_program | model_fields: fields}

      {:error, e} ->
        {:error, e}
    end
  end

  defp fetch_update_from_llm(ellm_program) do
    fetch_from_llm(ellm_program, &generate_update(&1, &2), :update)
  end

  # def respond_to_feedback_with_llm({:ok, idk}) do
  #   IO.inspect({:ok, idk})
  # end

  # def respond_to_feedback_with_llm({:error, idk}) do
  #   # msg = generate_feedback(blueprint, &LLM.user_message/1)
  #   # res = LLM.chat_completions([msg])
  #   IO.inspect(idk)
  # end

  def respond_to_feedback_with_llm(%EllmProgram{} = ellm_program) do
    msg = generate_feedback(ellm_program, &LLM.user_message/1)
    res = LLM.chat_completions([msg])

    case res do
      {:ok, %{choices: [%{message: %{content: feedback}}]}} ->
        %{ellm_program | feedback: feedback}

      {:error, e} ->
        {:error, e}
    end
  end

  defp fetch_view_from_llm(ellm_program) do
    fetch_from_llm(ellm_program, &generate_view(&1, &2), :view)
  end

  defp fetch_init_from_llm(ellm_program) do
    fetch_from_llm(ellm_program, &generate_init(&1, &2), :init)
  end

  def fetch_messages_from_llm(ellm_program) do
    fetch_from_llm(ellm_program, &generate_messages(&1, &2), :messages)
  end

  defp convert_messages_to_elm_type_alias(%EllmProgram{messages: messages} = ellm_program) do
    fetch_from_llm(
      ellm_program,
      fn _ -> generate_msg_alias(messages, &LLM.user_message/1) end,
      :msg
    )
  end

  defp convert_fields_to_elm_type_alias(%EllmProgram{model_fields: fields} = ellm_program) do
    msg = generate_type_alias(fields, &LLM.user_message/1)
    res = LLM.chat_completions([msg])

    case res do
      {:ok, %{choices: [%{message: %{content: type_alias}}]}} ->
        %{ellm_program | model_alias: type_alias}

      {:error, e} ->
        {:error, e}
    end
  end

  defp convert_fields_to_elm_type_alias(%EllmProgram{model_fields: fields} = ellm_program) do
    fetch_from_llm(
      ellm_program,
      fn _ -> generate_type_alias(fields, &LLM.user_message/1) end,
      :model_alias
    )
  end

  defp fetch_from_llm(ellm_program, generator_function, attribute_to_update) do
    msg = generator_function.(ellm_program, &LLM.user_message/1)

    available_functions_msg =
      """
      You have access to the following Elm functions:
      import Array exposing (Array, length, get)
      -- length : Array a -> Int
      -- get : Int -> Array a -> Maybe a
      """
      |> LLM.system_message()

    res = LLM.chat_completions([available_functions_msg, msg])

    case res do
      {:ok, %{choices: [%{message: %{content: content}}]}} ->
        Map.put(ellm_program, attribute_to_update, content)

      {:error, e} ->
        {:error, e}
    end
  end

  def generate(
        %{
          title: title,
          description: description,
          works: works
        },
        present
      ) do
    message = """
    Given the title: #{title}, the description: #{description}, and the user acceptance criteria #{works}, what are the fields that are necessary to create a working Elm application that matches the input.

    List out the fields as a list of strings with their types. Your response should look something like this:
    ```
    [ "field1" : "field1sType"
    , "field2" : "field2sType"
    ]
    DO NOT include the Msg in your response.
    Only inlcude basic types like String, Int, Float, Bool, etc.
    Don not rely on custom created types.
    """

    present.(message)
  end

  def generate_type_alias(fields, present) do
    message = """
    Turn this list of fields: #{fields} into a Elm type alias called Model. Each field should be on its own line.

    So for example if the fields given were:
    ```
      [ ("color", String)
      , ("size", Int)
      ]
    ```

    Then your response should look like this:
    ```
    type alias Model =
      { color : String
      , size : Int
      }
    """

    present.(message)
  end

  def generate_msg_alias(messages, present) do
    message = """
    Turn this list of messages: #{messages} into a Elm type alias called Msg. Each message should be on its own line.

    So for example if the messages given were:
    ```
      [ ("ChangeColor", String)
      , ("ChangeSize", Int)
      ]
    ```

    Then your response should look like this:
    ```
    type Msg = ChangeColor String | ChangeSize Int
    Keep it on one line.
    """

    present.(message)
  end

  def generate_feedback(ellm_program, present) do
    message = """
    Given this elm error message:
    #{ellm_program.error}
    Please provide a correction on how you would fix the error message
    This was your task
    #{stage_task(ellm_program.stage)}

    """

    present.(message)
  end

  def stage_task(_blurp) do
    "TODO"
  end

  def generate_init(
        ellm_program,
        present
      ) do
    message = """
    Given the following model alias:
    #{ellm_program.model_alias}
    Please generate the init function for the Elm Program.
    Only respond with the expression that is the init function.
    For example:
    type alias Model = { name : String }
    You would respond with:

    { name = "Bob" }
    """

    present.(message)
  end

  def generate_messages(
        ellm_program,
        present
      ) do
    message = """
    Given the following model alias:
    #{ellm_program.model_alias}
    Please generate the messages for the Elm Program.
    Only respond with the expression that is the messages.
    For example:
    type alias Model = { name : String }
    You would respond with:

    type Msg = ChangeName String
    """

    present.(message)
  end

  def generate_update(
        ellm_program,
        present
      ) do
    message = """
    Given the following model alias:
    #{ellm_program.model_alias}
    and the
    #{ellm_program.messages}
    Please generate the update function for the Elm Program.
    Only respond with the expression that is the update function.
    For example:
    type alias Model = { name : String }
    type Msg = ChangeName String
    You would respond with:

    update : Msg -> Model -> Model
    update msg model =
        case msg of
            ChangeName name ->
            { model | name = name }


    """

    present.(message)
  end

  def generate_view(ellm_program, present) do
    message = """
    Given the following model alias:
    #{ellm_program.model_alias}
    and the
    #{ellm_program.messages}
    Please generate the view function for the Elm Program.
    Only respond with the expression that is the view function.
    For example:
    type alias Model = { name : String }
    type Msg = ChangeName String
    You would respond with:

    view : Model -> Html Msg
    view model =
        div []
            [ input [ onInput ChangeName ] []
            , div [] [ text model.name ]
            ]

    """

    present.(message)
  end

  defp compile_elm_program(%EllmProgram{} = ellm_program, opts \\ []) do
    program_test = EllmProgram.to_string(ellm_program)
    output = Keyword.get(opts, :output, nil)

    if output do
      case ElmMakeServer.gen_js(program_test) do
        {:ok, _output} -> {:ok, %{ellm_program | code: program_test}}
        {:error, e} -> {:error, e}
      end
    else
      case ElmMakeServer.make_elm(program_test) do
        {:ok, _output} ->
          Logger.info("Successfully compiled Elm program Stage:#{inspect(ellm_program.stage)}")
          Events.broadcast("elm_compiled", %{ellm_program | code: program_test})

          {:ok, %{ellm_program | code: program_test}}

        {:error, e} ->
          Logger.error(
            "Elm Compile Failed #{inspect(ellm_program)} Stage:#{inspect(ellm_program.stage)}"
          )

          [hd_error | _errors] = e |> Jason.decode!() |> Map.get("errors")

          decoded_errors =
            Enum.map(hd_error["problems"], fn problem ->
              %{title: problem["title"], message: problem["message"]}
            end)
            |> Enum.map(fn x -> Enum.filter(x.message, fn x -> not is_map(x) end) end)
            |> dbg

          Events.broadcast("elm_compile_failed", %{ellm_program | error: decoded_errors})

          {:error, %{ellm_program | error: decoded_errors}}
      end
    end
  end
end
