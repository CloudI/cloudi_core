defmodule CloudICore.Mixfile do
  use Mix.Project

  def project do
    [app: :cloudi_core,
     version: "1.5.4",
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
    [{:cpg, "~> 1.5.4"},
     {:uuid, "~> 1.5.4", hex: :uuid_erl},
     {:reltool_util, "~> 1.5.4"},
     {:trie, "~> 1.5.4"},
     {:erlang_term, "~> 1.5.4"},
     {:quickrand, "~> 1.5.4"},
     {:pqueue, "~> 1.5.4"},
     {:key2value, "~> 1.5.4"},
     {:keys1value, "~> 1.5.4"},
     {:nodefinder, "~> 1.5.4"},
     {:supool, "~> 1.5.4"},
     {:varpool, "~> 1.5.4"},
     {:syslog, "~> 1.0.2"},
     {:msgpack, "~> 0.6.0"}]
  end

  defp description do
    "Erlang/Elixir Cloud Framework"
  end

  defp package do
    [files: ~w(src include doc test rebar.config README.markdown LICENSE
               cloudi.conf),
     maintainers: ["Michael Truog"],
     licenses: ["BSD"],
     links: %{"Website" => "http://cloudi.org",
              "GitHub" => "https://github.com/CloudI/cloudi_core"}]
   end
end
