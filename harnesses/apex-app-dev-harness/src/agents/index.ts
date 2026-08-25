// SPDX-License-Identifier: MIT
import Escalator from './escalator.js';
import Architect from './architect.js';
import Implementer from './implementer.js';
import Reviewer from './reviewer.js';
import TestWriter from './test-writer.js';
import Evaluator from './evaluator.js';
import Orchestrator from './orchestrator.js';

export const agents = [
  Escalator,
  Architect,
  Implementer,
  Reviewer,
  TestWriter,
  Evaluator,
  Orchestrator,
];

export default agents;
