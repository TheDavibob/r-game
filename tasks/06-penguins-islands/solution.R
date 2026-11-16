ggplot(penguins, aes(x = island, fill = species)) +
  geom_bar() +
  labs(title = "Penguins per island")
