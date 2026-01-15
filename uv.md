### \. Preparación del Entorno con `uv`

Estos comandos crearán tu proyecto, instalarán las dependencias (`boto3`) y activarán el entorno virtual.

**Crear proyecto e instalar dependencias:**

```bash
# 1. inicializa el proyecto
uv init

# 2. Instalar boto3 (la librería de AWS para Python)
uv add boto3
uv add loguru

# 3. Crear el entorno virtual (si no se creó automáticamente con init)
uv venv
```

**Activar el entorno virtual:**

- **Linux / macOS:**

  ```bash
  source .venv/bin/activate
  ```

- **Windows (PowerShell):**

  ```powershell
  .venv\Scripts\activate
  ```

- **Windows (CMD):**

  ```cmd
  .venv\Scripts\activate.bat
  ```

---
