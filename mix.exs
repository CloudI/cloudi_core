#-*-Mode:elixir;coding:utf-8;tab-width:2;c-basic-offset:2;indent-tabs-mode:()-*-
# ex: set ft=elixir fenc=utf-8 sts=2 ts=2 sw=2 et nomod:

defmodule CloudICore.Mixfile do
  use Mix.Project

  def project do
    [app: :cloudi_core,
     version: "2.0.5",
     language: :erlang,
     erlc_options: [
       {:d, :erlang.list_to_atom('ERLANG_OTP_VERSION_' ++ :erlang.system_info(:otp_release))},
       :deterministic,
       :debug_info,
       :warn_export_vars,
       :warn_unused_import,
       #:warn_missing_spec,
       :warnings_as_errors],
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
       :syntax_tools,
       :compiler],
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
    [{:cpg, ">= 2.0.5"},
     {:uuid, ">= 2.0.5", [hex: :uuid_erl]},
     {:reltool_util, ">= 2.0.5"},
     {:trie, ">= 2.0.5"},
     {:erlang_term, ">= 2.0.5"},
     {:quickrand, ">= 2.0.5"},
     {:pqueue, ">= 2.0.5"},
     {:key2value, ">= 2.0.5"},
     {:keys1value, ">= 2.0.5"},
     {:nodefinder, ">= 2.0.5"},
     {:supool, ">= 2.0.5"},
     {:varpool, ">= 2.0.5"},
     {:syslog_socket, ">= 2.0.5"}]
  end

  defp description do
    "Erlang/Elixir Cloud Framework"
  end

  defp package do
    [files: ~w(src include doc test rebar.config README.markdown LICENSE
               cloudi.conf),
     maintainers: ["Michael Truog"],
     licenses: ["MIT"],
     links: %{"Website" => "https://cloudi.org",
              "GitHub" => "https://github.com/CloudI/cloudi_core"}]
   end
end
