ExUnit.start([timeout: :infinity])

defmodule AssertValue.IntegrationTest.Support do

  # This helper is used to start external process, feed it with input,
  # and collect output.
  #
  # Inspired by Sasa Juric's post about running external programs with
  # Elixir's Port module:
  #   http://theerlangelist.blogspot.com/2015/08/outside-elixir.html
  #
  # and Alexei Sholik's Porcelain basic driver
  #   https://github.com/alco/porcelain/tree/master/lib/porcelain/drivers
  #
  # Usage example:
  # Run integration test session as external process, provide "yes" answers
  # for two prompts, and collect output and test results code:
  #
  #   {output, exit_code} = AssertValue.System.exec("mix",
  #      ["test", "--seed", "0", "/tmp/intergration_test.exs"], input: "y\ny\n")
  def exec(cmd, args, env, opts) do
    cmd = cmd |> System.find_executable
    port = Port.open({:spawn_executable, cmd},
      [{:args, args}, {:env, env}, :binary, :exit_status])
    Port.command(port, opts[:input])
    handle_output(port, "")
  end

  # This function recursively collects data provided by external
  # process indentified with port until it get :exit_status message.
  defp handle_output(port, output) do
    receive do
      {^port, {:data, data}} ->
        handle_output(port, output <> data)
      {^port, {:exit_status, exit_code}} ->
        {output, exit_code}
    end
  end

  @integration_test_dir Path.expand("integration", __DIR__)

  def prepare_runnable_test(basename, runnable_test_dir) do
    before_path = Path.expand(basename <> ".before", @integration_test_dir)
    after_path = Path.expand(basename <> ".after", @integration_test_dir)
    output_path = Path.expand(basename <> ".output", @integration_test_dir)

    # copy the test to a temp dir for running
    runnable_path = Path.expand(basename, runnable_test_dir)
    File.cp!(before_path, runnable_path)
    {runnable_path, after_path, output_path}
  end

  def run_tests(filename, env \\ []) do
    # extract expected assert_value prompt responses from the test.
    # We look for lines like '# prompt: y'
    prompt_responses =
      Regex.scan(~r/#\s*prompt:\s*(.)/, File.read!(filename))
      |> Enum.map(fn([_, x]) -> x end)
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    {output, exit_code} = AssertValue.IntegrationTest.Support.exec("mix",
      ["test", "--seed", "0", filename], env, input: prompt_responses)

    # Canonicalize output
    output =
      output
      |> String.replace(~r{\/tmp\/assert-value-\d+-\d+-\w+/}, "")
      |> String.replace(~r/\nFinished in.*\n/m, "")
      |> String.replace(~r/\nRandomized with seed.*\n/m, "")
      # mask line numbers
      |> String.replace(~r/(_test.exs:)\d+/, "\\1##")
      # canonicalize ExUnit error formatting:
      # - remove fancy spacing
      |> String.replace(~r/\s{5}code:\s+actual/m,   "     code: actual")
      |> String.replace(~r/\s{5}(left):\s+"/m,  "     left: \"")
      |> String.replace(~r/\s{5}(right):\s+"/m, "     right: \"")
      # canonicalize messages about raised exceptions
      # ExUnit in Elixir 1.5 has "code:" line in message:
      #
      #   ** (RuntimeError) Error!
      #   code: raise "Error!"
      #   stacktrace:
      #     integration_test.exs:82: (test)
      #
      # ExUnit in Elixir 1.4 does not
      #
      #   ** (RuntimeError) Error!
      #   stacktrace:
      #     integration_test.exs:82: (test)
      #
      |> String.replace(
        ~r/(\*\* \(.*?Error\).*?)\n\s{5}code:.*?\n/,
        "\\1\n"
      )

    {output, exit_code}
  end

  def prepare_expected_files(filenames, runnable_test_dir) do
    Enum.map(filenames, fn(filename) ->
      before_path = Path.expand(filename <> ".before", @integration_test_dir)
      after_path = Path.expand(filename <> ".after", @integration_test_dir)
      runnable_path = Path.expand(filename, runnable_test_dir)
      if File.exists?(before_path) do
        File.cp!(before_path, runnable_path)
      end
      [runnable_path, after_path]
    end)
  end

  # Integration test flow:
  # * Copy integration_test.exs.before to runnable_test_dir
  # * launch a child `mix test integration_test.exs`
  # * accept or reject assert_value changes when prompted
  # * compare test source file itself after the run with a reference copy
  # * compare test output with a reference copy
  #
  # We build the integration test module instead of just test to run
  # integration tests async
  #
  # Usage:
  #
  # import AssertValue.IntegrationTest.Support, only: [build_test_module: 3]
  # build_test_module :ParserTest, "parser_test.exs",
  #   env: [{'ASSERT_VALUE_ACCEPT_DIFFS', 'ask'}],
  #   expected_exit_code: 0,
  #   expected_files: ["file_to_create", "file_to_update"]
  #
  defmacro build_test_module(module_name, test_filename, opts \\ []) do
    expected_files = Keyword.get(opts, :expected_files, [])
    expected_exit_code = Keyword.get(opts, :expected_exit_code, 0)
    {:ok, runnable_test_dir} = Temp.mkdir("assert-value")
    test_name = "running integration #{module_name}"

    quote do

      defmodule unquote(module_name) do
        use ExUnit.Case, async: true

        import AssertValue
        import AssertValue.IntegrationTest.Support, only: [
          prepare_runnable_test: 2, prepare_expected_files: 2, run_tests: 2
        ]

        setup_all do
          # Make sure we delete temporary dir even if tests fail
          on_exit fn ->
            File.rm_rf!(unquote(runnable_test_dir))
          end
          :ok
        end

        test unquote(test_name) do
          {runnable_path, after_path, output_path} = prepare_runnable_test(
            unquote(test_filename), unquote(runnable_test_dir)
          )
          expected_files = prepare_expected_files(
            unquote(expected_files), unquote(runnable_test_dir)
          )
          {output, exit_code} = run_tests(runnable_path, unquote(opts[:env]))
          assert exit_code == unquote(expected_exit_code)
          test_source_result = File.read!(runnable_path)
          # Make sure resulting test file is valid Elixir code
          # Will raise SyntaxError or TokenMissingError otherwise
          Code.string_to_quoted!(test_source_result)
          assert_value test_source_result == File.read!(after_path)
          assert_value output == File.read!(output_path)
          Enum.each(expected_files, fn([runnable_path, after_path]) ->
            assert_value(File.read!(runnable_path) == File.read!(after_path))
          end)
        end
      end

    end # quote do
  end # defmacro

end
