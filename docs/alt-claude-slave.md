# OpenDesign + alt-claude-slave

Esta integração usa o OpenCode como ponte entre o OpenDesign e o
`alt-claude-slave`.

Fluxo:

```text
OpenDesign
  -> runtime OpenCode
  -> provider OpenAI-compatible "alt-claude"
  -> llama-server do alt-claude-slave
```

Esse caminho é intencional. O modo BYOK direto do OpenDesign possui proteção
SSRF para destinos privados; já o runtime OpenCode é um processo local e o
OpenCode suporta providers OpenAI-compatible com `baseURL` customizada.

## Pré-requisitos

- OpenDesign instalado deste repositório;
- OpenCode disponível como `opencode-cli` ou `opencode`;
- `alt-claude-slave` com o llama-server ativo;
- o endpoint do llama-server deve ser alcançável pela máquina que executa o
  OpenDesign.

O padrão esperado é:

```text
http://127.0.0.1:8080/v1
```

Se o servidor estiver em outro host/container:

```bash
ALT_CLAUDE_BASE_URL=http://HOST:8080/v1 \
  bash scripts/setup-alt-claude-slave.sh
```

## Configuração

```bash
bash scripts/setup-alt-claude-slave.sh
```

O script:

1. verifica o endpoint `/v1/models`;
2. encontra `opencode-cli` ou `opencode`;
3. cria uma configuração isolada em
   `.local/alt-claude/opencode.json`;
4. registra o provider `alt-claude` usando
   `@ai-sdk/openai-compatible`;
5. confirma que o modelo aparece em `opencode models`.

Nenhuma configuração global do OpenCode é alterada.

O modelo padrão é `qwen-coder-3b`. Para usar outro:

```bash
ALT_CLAUDE_MODEL=qwen-coder-7b \
  bash scripts/setup-alt-claude-slave.sh
```

## Smoke test

Para testar também uma chamada real ao modelo:

```bash
bash scripts/setup-alt-claude-slave.sh --smoke
```

## Iniciar o OpenDesign

```bash
bash scripts/run-with-alt-claude-slave.sh
```

Ou, para iniciar somente web + daemon em foreground:

```bash
bash scripts/run-with-alt-claude-slave.sh run web
```

No OpenDesign, selecione:

```text
Execution mode: OpenCode
Model: alt-claude/qwen-coder-3b
```

O OpenDesign continuará responsável por compor `DESIGN.md`, skills e o
workspace. O OpenCode mantém o loop de agente e as ferramentas de filesystem;
o modelo local recebe o trabalho através do provider configurado.

## Variáveis

- `ALT_CLAUDE_BASE_URL`: endpoint OpenAI-compatible. Padrão:
  `http://127.0.0.1:8080/v1`.
- `ALT_CLAUDE_MODEL`: modelo exposto pelo llama-server. Padrão:
  `qwen-coder-3b`.
- `ALT_CLAUDE_API_KEY`: enviada pelo OpenCode ao endpoint. Para llama-server
  sem autenticação, o launcher usa `local-no-auth`.
- `ALT_CLAUDE_OPENCODE_DIR`: diretório da configuração isolada.

## Escopo

A primeira versão não altera o runtime interno do OpenDesign nem tenta burlar a
proteção SSRF do BYOK. Se o experimento provar que o modelo local é útil para
tarefas de design, podemos evoluir depois para um perfil/runtime dedicado.
