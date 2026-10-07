-- Pyproject.dhall: renders a crew's pyproject.toml from its directory name.
--
-- The pyproject.toml heredoc that used to live inside compile.sh is now a
-- Dhall function. The Makefile materializes it as raw text with:
--
--   echo '.dhall/Pyproject.dhall "e2e"' \
--     | dhall-to-json --omit-empty | jq -r . > build/e2e/pyproject.toml

let RenderPyproject = ∀(name : Text) → Text

in  ( λ(name : Text) → ''
    [project]
    name = "${name}"
    version = "0.1.0"
    description = "crewAI worker for ${name}"
    requires-python = ">=3.10,<3.14"

    [build-system]
    requires = ["hatchling"]
    build-backend = "hatchling.build"

    [tool.crewai]
    type = "crew"
    definition = "crew.json"
    '' ) : RenderPyproject