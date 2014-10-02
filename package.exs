defmodule CloudICore.Mixfile do
  use Mix.Project

  def project do
    [app: :cloudi_core,
     version: "1.3.3",
     description: description,
     package: package,
     deps: deps]
  end

  defp deps do
    [{:cpg,
      [git: "https://github.com/okeuday/cpg.git",
       tag: "v1.3.3"]},
     {:uuid,
      [git: "https://github.com/okeuday/uuid.git",
       tag: "v1.3.3"]},
     {:reltool_util,
      [git: "https://github.com/okeuday/reltool_util.git",
       tag: "v1.3.3"]},
     {:trie,
      [git: "https://github.com/okeuday/trie.git",
       tag: "v1.3.3"]},
     {:erlang_term, "~> 1.3.3",
      [compile: "rebar compile"]},
     {:quickrand,
      [git: "https://github.com/okeuday/quickrand.git",
       tag: "v1.3.3"]},
     {:pqueue, "~> 1.3.3"},
     {:key2value, "~> 1.3.3",
      [compile: "rebar compile"]},
     {:keys1value, "~> 1.3.3",
      [compile: "rebar compile"]},
     {:nodefinder,
      [git: "https://github.com/okeuday/nodefinder.git",
       tag: "v1.3.2"]},
     {:dynamic_compile,
      [git: "https://github.com/okeuday/dynamic_compile.git",
       tag: "v1.3.3"]},
     {:syslog,
      [git: "https://github.com/okeuday/erlang-syslog.git",
       tag: "1.0.3"]}]
  end

  defp description do
    "Erlang/Elixir Cloud Framework"
  end

  defp package do
    [files: ~w(src doc include test rebar.config README.markdown cloudi.conf),
     contributors: ["Michael Truog"],
     licenses: ["BSD"],
     links: %{"Website" => "http://cloudi.org",
              "GitHub" => "https://github.com/CloudI/cloudi_core"}]
   end
end
