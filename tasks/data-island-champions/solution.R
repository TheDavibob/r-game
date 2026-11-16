penguins |>
  group_by(island) |>
  slice_max(body_mass_g, n = 1) |>
  ungroup() |>
  select(island, species, sex, body_mass_g)
