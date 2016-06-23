defmodule CloudICore.Mixfile do
  use Mix.Project

  def project do
    [app: :cloudi_core,
     version: "1.5.1-package",
     language: :erlang,
     description: description,
     package: package,
     deps: deps]
  end

  def application do
    [applications: [
       :nodefinder,
       :dynamic_compile,
       :pqueue,
       :quickrand,
       :supool,
       :varpool,
       :trie,
       :reltool_util,
       :key2value,
       :keys1value,
       :uuid,
       :erlang_term,
       :cpg,
       :msgpack,
       :sasl],
     included_applications: [
       :syslog],
     mod: {:cloudi_core_i_app, []},
     registered: [
       :cloudi_core_i_configurator,
       :cloudi_core_i_logger,
       :cloudi_core_i_logger_sup,
       :cloudi_core_i_nodes,
       :cloudi_core_i_os_spawn,
       :cloudi_core_i_services_external_sup,
       :cloudi_core_i_services_internal_reload,
       :cloudi_core_i_services_internal_sup,
       :cloudi_core_i_services_monitor]]
  end

  defp deps do
    [{:cpg, "~> 1.5.1"},
     {:uuid, "~> 1.5.1", hex: :uuid_erl},
     {:reltool_util, "~> 1.5.1"},
     {:trie, "~> 1.5.1"},
     {:erlang_term, "~> 1.5.1"},
     {:quickrand, "~> 1.5.1"},
     {:pqueue, "~> 1.5.1"},
     {:key2value, "~> 1.5.1"},
     {:keys1value, "~> 1.5.1"},
     {:nodefinder, "~> 1.5.1"},
     {:supool, "~> 1.5.1"},
     {:varpool, "~> 1.5.1"},
     {:dynamic_compile, "~> 1.0.0"},
     {:syslog, "~> 1.0.2"},
     {:msgpack, "~> 0.3.5"}]
  end

  defp description do
    "Erlang/Elixir Cloud Framework"
  end

  defp package do
    [files: ~w(src include doc test rebar.config README.markdown cloudi.conf),
     maintainers: ["Michael Truog"],
     licenses: ["BSD"],
     links: %{"Website" => "http://cloudi.org",
              "GitHub" => "https://github.com/CloudI/cloudi_core"}]
   end
end
