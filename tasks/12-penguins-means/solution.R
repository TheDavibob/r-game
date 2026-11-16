known <- subset(penguins, !is.na(sex))
avg <- aggregate(body_mass_g ~ species + sex, data = known, FUN = mean)

ggplot(avg, aes(x = species, y = body_mass_g, fill = sex)) +
  geom_col(position = "dodge") +
  labs(y = "Mean body mass (g)", title = "Average penguin body mass")
