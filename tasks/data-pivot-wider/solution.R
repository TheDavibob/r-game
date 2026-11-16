penguins |>
  count(island, species) |>
  pivot_wider(names_from = species, values_from = n, values_fill = 0)
