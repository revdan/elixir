Code.require_file "../test_helper.exs", __DIR__

defmodule Mix.DepTest do
  use MixTest.Case

  defmodule DepsApp do
    def project do
      [ deps: [
          {:ok,         "0.1.0", path: "deps/ok"},
          {:invalidvsn, "0.2.0", path: "deps/invalidvsn"},
          {:invalidapp, "0.1.0", path: "deps/invalidapp"},
          {:noappfile,  "0.1.0", path: "deps/noappfile"},
          {:uncloned,            git: "https://github.com/elixir-lang/uncloned.git"},
          {:optional,            git: "https://github.com/elixir-lang/optional.git", optional: true}
        ] ]
    end
  end

  defmodule ProcessDepsApp do
    def project do
      [deps: Process.get(:mix_deps)]
    end
  end

  defp with_deps(deps, fun) do
    Process.put(:mix_deps, deps)
    Mix.Project.push ProcessDepsApp
    fun.()
  after
    Mix.Project.pop
  end

  defp assert_wrong_dependency(deps) do
    with_deps deps, fn ->
      assert_raise Mix.Error, ~r"Dependency specified in the wrong format", fn ->
        Mix.Dep.loaded([])
      end
    end
  end

  test "extracts all dependencies from the given project" do
    Mix.Project.push DepsApp

    in_fixture "deps_status", fn ->
      deps = Mix.Dep.loaded([])
      assert length(deps) == 6
      assert Enum.find deps, &match?(%Mix.Dep{app: :ok, status: {:ok, _}}, &1)
      assert Enum.find deps, &match?(%Mix.Dep{app: :invalidvsn, status: {:invalidvsn, :ok}}, &1)
      assert Enum.find deps, &match?(%Mix.Dep{app: :invalidapp, status: {:invalidapp, _}}, &1)
      assert Enum.find deps, &match?(%Mix.Dep{app: :noappfile, status: {:noappfile, _}}, &1)
      assert Enum.find deps, &match?(%Mix.Dep{app: :uncloned, status: {:unavailable, _}}, &1)
      assert Enum.find deps, &match?(%Mix.Dep{app: :optional, status: {:unavailable, _}}, &1)
    end
  end

  test "fails on invalid dependencies" do
    assert_wrong_dependency [{:ok}]
    assert_wrong_dependency [{:ok, nil}]
    assert_wrong_dependency [{:ok, nil, []}]
  end

  test "use requirements for dependencies" do
    with_deps [{:ok, "~> 0.1", path: "deps/ok"}], fn ->
      in_fixture "deps_status", fn ->
        deps = Mix.Dep.loaded([])
        assert Enum.find deps, &match?(%Mix.Dep{app: :ok, status: {:ok, _}}, &1)
      end
    end
  end

  test "raises when no SCM is specified" do
    with_deps [{:ok, "~> 0.1", not_really: :ok}], fn ->
      in_fixture "deps_status", fn ->
        send self, {:mix_shell_input, :yes?, false}
        msg = "Could not find a SCM for dependency :ok from Mix.DepTest.ProcessDepsApp"
        assert_raise Mix.Error, msg, fn -> Mix.Dep.loaded([]) end
      end
    end
  end

  test "does not set the manager before the dependency was loaded" do
    # It is important to not eagerly set the manager because the dependency
    # needs to be loaded (i.e. available in the filesystem) in order to get
    # the proper manager.
    Mix.Project.push DepsApp

    {_, true, _} =
      Mix.Dep.Converger.converge(false, [], nil, fn dep, acc, lock ->
        assert is_nil(dep.manager)
        {dep, acc or true, lock}
      end)
  end

  test "raises on invalid deps req" do
    with_deps [{:ok, "+- 0.1.0", path: "deps/ok"}], fn ->
      in_fixture "deps_status", fn ->
        assert_raise Mix.Error, ~r"Invalid requirement", fn ->
          Mix.Dep.loaded([])
        end
      end
    end
  end

  defmodule NestedDepsApp do
    def project do
      [
        app: :raw_sample,
        version: "0.1.0",
        deps: [
          {:deps_repo, "0.1.0", path: "custom/deps_repo"}
        ]
      ]
    end
  end

  test "nested deps come first" do
    Mix.Project.push NestedDepsApp

    in_fixture "deps_status", fn ->
      assert Enum.map(Mix.Dep.loaded([]), &(&1.app)) == [:git_repo, :deps_repo]
    end
  end

  test "nested optional deps are never added" do
    Mix.Project.push NestedDepsApp

    in_fixture "deps_status", fn ->
      File.write! "custom/deps_repo/mix.exs", """
      defmodule DepsRepo do
        use Mix.Project

        def project do
          [
            app: :deps_repo,
            version: "0.1.0",
            deps: [
              {:git_repo, "0.2.0", git: MixTest.Case.fixture_path("git_repo"), optional: true}
            ]
          ]
        end
      end
      """

      assert Enum.map(Mix.Dep.loaded([]), &(&1.app)) == [:deps_repo]
    end
  end

  defmodule ConvergedDepsApp do
    def project do
      [
        app: :raw_sample,
        version: "0.1.0",
        deps: [
          {:deps_repo, "0.1.0", path: "custom/deps_repo"},
          {:git_repo, "0.1.0", git: MixTest.Case.fixture_path("git_repo")}
        ]
      ]
    end
  end

  test "correctly order converged deps" do
    Mix.Project.push ConvergedDepsApp

    in_fixture "deps_status", fn ->
      assert Enum.map(Mix.Dep.loaded([]), &(&1.app)) == [:git_repo, :deps_repo]
    end
  end

  test "correctly order converged deps even with optional dependencies" do
    Mix.Project.push ConvergedDepsApp

    in_fixture "deps_status", fn ->
      File.write! "custom/deps_repo/mix.exs", """
      defmodule DepsRepo do
        use Mix.Project

        def project do
          [
            app: :deps_repo,
            version: "0.1.0",
            deps: [
              {:git_repo, "0.2.0", git: MixTest.Case.fixture_path("git_repo"), optional: true}
            ]
          ]
        end
      end
      """

      assert Enum.map(Mix.Dep.loaded([]), &(&1.app)) == [:git_repo, :deps_repo]
    end
  end

  defmodule IdentityRemoteConverger do
    @behaviour Mix.RemoteConverger

    def remote?(_app), do: true

    def converge(_deps, lock) do
      Process.put(:remote_converger, true)
      lock
    end

    def deps(_deps, _lock) do
      []
    end
  end

  test "remote converger" do
    Mix.Project.push ConvergedDepsApp
    Mix.RemoteConverger.register(IdentityRemoteConverger)

    in_fixture "deps_status", fn ->
      Mix.Tasks.Deps.Get.run([])

      message = "* Getting git_repo (#{fixture_path("git_repo")})"
      assert_received {:mix_shell, :info, [^message]}

      assert Process.get(:remote_converger)
    end
  after
    Mix.RemoteConverger.register(nil)
  end

  test "only extract deps matching environment" do
    with_deps [{:foo, github: "elixir-lang/foo"},
               {:bar, github: "elixir-lang/bar", only: :other_env}], fn ->
      in_fixture "deps_status", fn ->
        deps = Mix.Dep.loaded([env: :other_env])
        assert length(deps) == 2

        deps = Mix.Dep.loaded([])
        assert length(deps) == 2

        deps = Mix.Dep.loaded([env: :prod])
        assert length(deps) == 1
        assert Enum.find deps, &match?(%Mix.Dep{app: :foo}, &1)
      end
    end
  end

  test "only fetch child deps matching prod env" do
    with_deps [{:only_deps, path: fixture_path("only_deps")}], fn ->
      in_fixture "deps_status", fn ->
        Mix.Tasks.Deps.Get.run([])
        message = "* Getting git_repo (#{fixture_path("git_repo")})"
        refute_received {:mix_shell, :info, [^message]}
      end
    end
  end

  test "only fetch parent deps matching specified env" do
    with_deps [{:only, github: "elixir-lang/only", only: [:dev]}], fn ->
      in_fixture "deps_status", fn ->
        Mix.Tasks.Deps.Get.run(["--only", "prod"])
        refute_received {:mix_shell, :info, ["* Getting" <> _]}

        assert_raise Mix.Error, "Can't continue due to errors on dependencies", fn ->
          Mix.Tasks.Deps.Check.run([])
        end

        Mix.env(:prod)
        Mix.Tasks.Deps.Check.run([])
      end
    end
  end
end
