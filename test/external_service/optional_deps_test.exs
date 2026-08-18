defmodule ExternalService.OptionalDepsTest do
  use ExUnit.Case, async: true

  # `:decorator` and `:flow` are declared `optional: true`, which is only true in
  # practice as long as nothing in the core refers to them. `ExternalService.Flow`
  # and `ExternalService.Decorator` each compile behind a `Code.ensure_loaded?/1`
  # guard, so they simply do not exist for a consumer who did not install the
  # dependency — but a reference from any *other* module would then fail to
  # compile in that consumer's project.
  #
  # That failure is invisible here, because this suite has both dependencies
  # installed. So rather than exercising behavior, this reads the compiled
  # modules: every remote call a module makes is recorded in its BEAM `imports`
  # chunk, which cannot be fooled by a mention in a moduledoc or a comment.

  @optional_roots [Decorator, Flow]
  @guarded_modules [ExternalService.Decorator, ExternalService.Flow]

  test "no core module calls into an optional dependency" do
    {:ok, modules} = :application.get_key(:external_service, :modules)

    offenders =
      modules
      |> Enum.reject(&(&1 in @guarded_modules))
      |> Enum.flat_map(fn module ->
        case optional_calls(module) do
          [] -> []
          calls -> [{module, calls}]
        end
      end)

    assert offenders == [],
           """
           These modules call into an optional dependency, which would break \
           compilation for consumers who have not installed it:

           #{inspect(offenders, pretty: true)}
           """
  end

  test "both guarded modules are present here, so the check above is meaningful" do
    # If the dependencies ever stopped being installed for this project, the test
    # above would pass vacuously.
    for module <- @guarded_modules do
      assert Code.ensure_loaded?(module), "#{inspect(module)} is not compiled in this project"
    end
  end

  defp optional_calls(module) do
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])

    Enum.filter(imports, fn {called, _fun, _arity} -> optional?(called) end)
  end

  defp optional?(module) do
    name = Atom.to_string(module)

    Enum.any?(@optional_roots, fn root ->
      root_name = Atom.to_string(root)
      name == root_name or String.starts_with?(name, root_name <> ".")
    end)
  end
end
