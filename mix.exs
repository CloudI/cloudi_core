defmodule CloudICore.Mixfile do
  use Mix.Project

  def project do
    [app: :cloudi_core,
     version: "1.4.0",
     language: :erlang,
     description: description,
     package: package,
     deps: deps]
  end

  defp deps do
    [{:cpg, "~> 1.4.0"},
     {:uuid, "~> 1.4.0", hex: :uuid_erl},
     {:reltool_util, "~> 1.4.0"},
     {:trie, "~> 1.4.0"},
     {:erlang_term, "~> 1.4.0"},
     {:quickrand, "~> 1.4.0"},
     {:pqueue, "~> 1.4.0"},
     {:key2value, "~> 1.4.0"},
     {:keys1value, "~> 1.4.0"},
     {:nodefinder, "~> 1.4.0"},
     {:dynamic_compile, "~> 1.0.0"},
     {:syslog, "~> 1.0.2"}]
  end

  defp description do
    "Erlang/Elixir Cloud Framework"
  end

  defp package do
    [files: ~w(src include doc test rebar.config README.markdown cloudi.conf),
     contributors: ["Michael Truog"],
     licenses: ["BSD"],
     links: %{"Website" => "http://cloudi.org",
              "GitHub" => "https://github.com/CloudI/cloudi_core"}]
   end
end
