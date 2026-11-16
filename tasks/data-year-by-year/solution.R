penguins |>
  group_by(species, year) |>
  summarise(
    n = n(),
    median_mass = median(body_mass_g, na.rm = TRUE),
    .groups = "drop"
  )
