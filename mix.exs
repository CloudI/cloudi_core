defmodule CloudICore.Mixfile do
  use Mix.Project

  def project do
    [app: :cloudi_core,
     version: "1.5.3-rc1",
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
    [{:cpg, "~> 1.5.2"},
     {:uuid, "~> 1.5.2", hex: :uuid_erl},
     {:reltool_util, "~> 1.5.2"},
     {:trie, "~> 1.5.2"},
     {:erlang_term, "~> 1.5.2"},
     {:quickrand, "~> 1.5.2"},
     {:pqueue, "~> 1.5.2"},
     {:key2value, "~> 1.5.2"},
     {:keys1value, "~> 1.5.2"},
     {:nodefinder, "~> 1.5.3"},
     {:supool, "~> 1.5.2"},
     {:varpool, "~> 1.5.2"},
     {:syslog, "~> 1.0.2"},
     {:msgpack, "~> 0.6.0"}]
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
