// SPDX-License-Identifier: MIT
// Entry point for the apex-app-harness harness.
import { loadKernel, kernelDiagnostics, type KernelInfo } from '@metaharness/kernel';
import { readHarnessJson } from './paths.js';

export interface HarnessManifest {
  name: string;
  template?: string;
  agents?: string[];
  skills?: string[];
  commands?: string[];
  memory?: string;
  routing?: string;
  models?: Record<string, string>;
}

export interface HarnessRuntime {
  name: string;
  manifest: HarnessManifest;
  kernel: KernelInfo;
  backend: 'native' | 'wasm' | 'js';
}

/**
 * Load the kernel and the harness manifest. Everything the CLI and the MCP
 * server need to describe themselves honestly comes from here.
 */
export async function init(): Promise<HarnessRuntime> {
  const kernel = await loadKernel();
  const diagnostics = await kernelDiagnostics();
  const manifest = readHarnessJson<HarnessManifest>('manifest.json', {
    name: 'apex-app-harness',
  });
  return {
    name: manifest.name ?? 'apex-app-harness',
    manifest,
    kernel: kernel.kernelInfo(),
    backend: diagnostics.resolved,
  };
}
