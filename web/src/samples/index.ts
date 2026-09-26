// Synthetic scenes with the answers the placement server gave them, recorded by
// scripts/record_samples.py. The saved answer is shown only when the user asks for it after the
// live server could not be reached.
import cornerPlan from "./corner-not-walked/plan.svg?raw";
import cornerResult from "./corner-not-walked/result.json?raw";
import cornerScene from "./corner-not-walked/scene.json?raw";
import fitsPlan from "./fits/plan.svg?raw";
import fitsResult from "./fits/result.json?raw";
import fitsScene from "./fits/scene.json?raw";
import garagePlan from "./garage-in-the-way/plan.svg?raw";
import garageResult from "./garage-in-the-way/result.json?raw";
import garageScene from "./garage-in-the-way/scene.json?raw";

export interface Sample {
  id: string;
  title: string;
  about: string;
  scene: string;
  savedResult: string;
  savedPlan: string;
}

export const SAMPLES: readonly Sample[] = [
  {
    id: "fits",
    title: "Clear side wall",
    about: "A long side wall with a gas meter and a window left of the electric meter.",
    scene: fitsScene,
    savedResult: fitsResult,
    savedPlan: fitsPlan,
  },
  {
    id: "corner-not-walked",
    title: "Walk stopped at a corner",
    about: "A short wall; the homeowner stopped 9 ft to the right, where the house turns.",
    scene: cornerScene,
    savedResult: cornerResult,
    savedPlan: cornerPlan,
  },
  {
    id: "garage-in-the-way",
    title: "Garage in the way",
    about: "A garage door right of the meter and gas meters to its left.",
    scene: garageScene,
    savedResult: garageResult,
    savedPlan: garagePlan,
  },
];
