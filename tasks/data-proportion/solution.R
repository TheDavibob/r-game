penguins |>
  filter(!is.na(body_mass_g)) |>
  group_by(species) |>
  summarise(prop_heavy = mean(body_mass_g > 4500))
