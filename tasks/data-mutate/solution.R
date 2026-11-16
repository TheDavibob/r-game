penguins |>
  mutate(
    body_mass_kg = body_mass_g / 1000,
    bill_ratio = bill_length_mm / bill_depth_mm
  ) |>
  select(species, body_mass_kg, bill_ratio)
