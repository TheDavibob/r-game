ggplot(penguins, aes(x = flipper_length_mm, fill = species)) +
  geom_histogram(binwidth = 5) +
  facet_wrap(~species, ncol = 1)
