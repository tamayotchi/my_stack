defmodule TamayotchiStack.TaskInfoTest do
  use ExUnit.Case, async: true

  alias TamayotchiStack.TaskInfo

  test "reported conflicts and write failures are not successful CLI results" do
    assert_raise Mix.Error, ~r/could not apply all changes/, fn ->
      TaskInfo.ensure_success!(:issues)
    end
  end

  test "successful and deliberately declined Igniter results retain their behavior" do
    for result <- [:changes_made, :no_changes, :dry_run_with_no_changes, :changes_aborted] do
      assert TaskInfo.ensure_success!(result) == result
    end
  end
end
