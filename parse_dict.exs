#!/usr/bin/env iex

# this file prepares `dict.csv` downloaded off of:
# https://www.bragitoff.com/2016/03/english-dictionary-in-csv-format

Mix.install([
  {:csv, "~> 3.0"}
])

dict = File.stream!("dict.csv", [read_ahead: 100_000], 1000)
  |> CSV.decode!()
  |> Stream.map(fn [word, type, _definition] -> {String.downcase(word), type} end)
  |> Stream.filter(fn {_, type} -> type in ["n.", "a.", "adv.", "prep.", "v. t.", "v. i."] end)
  |> Stream.map(fn {word, type} -> {word, Map.get(%{
    "n."    => :noun,
    "a."    => :adj,
    "adv."  => :adv,
    "prep." => :prep,
    "v. t." => :verb,
    "v. i." => :verb}, type)} end)
  |> Enum.into([])

File.rm("priv/dict.dets")
{:ok, table} = :dets.open_file(:dictionary, file: 'priv/dict.dets', type: :set, ram_file: true)

for object <- dict do
  :dets.insert(table, object)
end

:dets.sync(table)
