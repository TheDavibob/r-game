penguins |>
  pivot_longer(
    c(bill_length_mm, bill_depth_mm, flipper_length_mm),
    names_to = "measurement",
    values_to = "value"
  ) |>
  group_by(species, measurement) |>
  summarise(mean_value = mean(value, na.rm = TRUE), .groups = "drop")
