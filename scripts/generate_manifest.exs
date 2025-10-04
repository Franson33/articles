Mix.install([{:jason, "~> 1.4"}])

defmodule ManifestGenerator do
  @articles_dir "articles"

  def generate do
    manifest =
      list_markdown_files()
      |> Enum.map(fn file ->
        file
        |> extract_slug()
        |> read_and_parse_file()
      end)
      |> Enum.reject(& &1["draft"])
      |> Enum.sort_by(& &1["date"], :desc)
      |> Jason.encode!(pretty: true)

    File.write!("manifest.json", manifest)

    IO.puts("✓ Generated manifest.json with #{length(Jason.decode!(json))} articles")
  end

  defp list_markdown_files() do
    @articles_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".md"))
  end

  defp extract_slug(file) do
    file
    |> String.replace(".md", "")
    |> then(fn slug -> [file, slug] end)
  end

  defp read_and_parse_file([file, slug]) do
    Path.join(@articles_dir, "/#{file}")
    |> File.read!()
    |> extract_frontmatter()
    |> parse_yaml()
    |> Map.put("slug", slug)
  end

  defp extract_frontmatter(text) do
    case Regex.run(~r/^---\n(.*?)\n---/s, text) do
      [_full_match, yaml] -> yaml
      nil -> ""
    end
  end

  defp parse_yaml(yaml) do
    yaml
    |> String.split("\n")
    |> Enum.map(&String.split(&1, ":", parts: 2))
    |> Enum.filter(&match?([_, _], &1))
    |> Enum.map(fn [k, v] -> {String.trim(k), String.trim(v) |> parse_value()} end)
    |> Enum.into(%{})
  end

  defp parse_value("true"), do: true
  defp parse_value("false"), do: false
  defp parse_value("\"" <> _ = value), do: String.trim(value, "\"")
  defp parse_value("[" <> _ = value), do: parse_tags(value)
  defp parse_value(value), do: value

  defp parse_tags(value) do
    value
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end
end

ManifestGenerator.generate()
