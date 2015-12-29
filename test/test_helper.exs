ExUnit.start()

defmodule AssertValue.Tempfile do
  def mktemp_dir(prefix \\ "", suffix \\ "") do
    name = Path.expand(generate_tmpname(prefix, suffix), System.tmp_dir!)
    File.mkdir_p!(name)
    name
  end

  # Inspired by ruby's tmpname (ruby/lib/tmpdir.rb) and elixir Plug's upload.ex
  defp generate_tmpname(prefix, suffix) do
    {_mega, sec, micro} = :os.timestamp
    pid = :os.getpid
    random_string = Integer.to_string(:rand.uniform(0x100000000), 36) |> String.downcase
    "#{prefix}#{sec}#{micro}-#{pid}-#{random_string}#{suffix}"
  end
end

defmodule AssertValue.TestHelpers do

  require AssertValue.Tempfile

  @integration_tests_dir Path.expand("integration", __DIR__)
  @target_dir AssertValue.Tempfile.mktemp_dir("assert-value-")

  def prepare_and_run_test_case(test_source_filename, input \\ "") do
    log_filename_with_path = test_source_filename |> test_log_filename_with_path
    {result, exitcode} =
      test_source_filename
      |> prepare_test_case
      |> run_test_case(input)
    {result, exitcode, log_filename_with_path}
  end

  def integration_tests_dir do
    @integration_tests_dir
  end

  defp test_case_filenames(test_source_filename) do
    source_filename = Path.expand(test_source_filename <> ".src", @integration_tests_dir)
    target_filename = Path.expand(test_source_filename, @target_dir)
    {source_filename, target_filename}
  end

  defp prepare_test_case(test_source_filename) do
    {source_filename, target_filename} =
      test_case_filenames(test_source_filename)
    File.cp!(source_filename, target_filename)
    target_filename
  end

  defp run_test_case(test_case_file, input) do
    %Porcelain.Result{out: output, status: exitcode} =
      Porcelain.exec("mix", ["test", test_case_file], in: input)
    # Serialize output
    output =
      output
      |> String.replace(~r{\/tmp\/assert-value-\d+-\d+-\w+/}, "")
      |> String.replace(~r/\nFinished in.*\n/m, "")
      |> String.replace(~r/\nRandomized with seed.*\n/m, "")
    {output, exitcode}
  end

  defp test_log_filename_with_path(test_source_filename) do
    Path.expand(test_source_filename <> ".log", @integration_tests_dir)
  end

  def test_source_diff(test_source_filename) do
    {original_file, updated_file} = test_case_filenames(test_source_filename)
    original_source = File.read!(original_file)
    updated_source = File.read!(updated_file)
    AssertValue.Diff.diff(original_source, updated_source)
  end

end
