defmodule CloudICore.Mixfile do
  use Mix.Project

  def project do
    [app: :cloudi_core,
     version: "1.6.0",
     language: :erlang,
     description: description(),
     package: package(),
     deps: deps()]
  end

  def application do
    [applications: [
       :nodefinder,
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
       :syslog_socket,
       :msgpack,
       :sasl,
       :syntax_tools],
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
    [{:cpg, "~> 1.6.0"},
     {:uuid, "~> 1.6.0", hex: :uuid_erl},
     {:reltool_util, "~> 1.6.0"},
     {:trie, "~> 1.6.0"},
     {:erlang_term, "~> 1.6.0"},
     {:quickrand, "~> 1.6.0"},
     {:pqueue, "~> 1.6.0"},
     {:key2value, "~> 1.6.0"},
     {:keys1value, "~> 1.6.0"},
     {:nodefinder, "~> 1.6.0"},
     {:supool, "~> 1.6.0"},
     {:varpool, "~> 1.6.0"},
     {:syslog_socket, "~> 1.6.0"},
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
