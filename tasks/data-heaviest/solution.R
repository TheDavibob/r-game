penguins |>
  arrange(desc(body_mass_g)) |>
  head(4) |>
  select(species, island, sex, body_mass_g)
