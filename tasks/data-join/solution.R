penguins |>
  left_join(species_info, by = "species") |>
  count(latin_name, year)
