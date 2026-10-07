"use strict";

const lwcConfig = require("@salesforce/eslint-config-lwc");
const jestPlugin = require("eslint-plugin-jest");
const globals = require("globals");

module.exports = [
    {
        ignores: ["**/node_modules/**", "**/.sfdx/**", "**/.sf/**", "coverage/**"]
    },
    ...lwcConfig.configs.recommended.map((config) => ({
        ...config,
        files: ["force-app/main/default/lwc/**/*.js"]
    })),
    {
        files: ["force-app/main/default/lwc/**/__tests__/**/*.js"],
        plugins: { jest: jestPlugin },
        languageOptions: {
            globals: { ...globals.node, ...globals.jest }
        },
        rules: {
            ...jestPlugin.configs.recommended.rules,
            "@lwc/lwc/no-unexpected-wire-adapter-usages": "off"
        }
    }
];
