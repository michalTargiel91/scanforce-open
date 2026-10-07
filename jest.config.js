const { jestConfig } = require("@salesforce/sfdx-lwc-jest/config");

module.exports = {
    ...jestConfig,
    modulePathIgnorePatterns: ["<rootDir>/.localdevserver"],
    collectCoverageFrom: ["force-app/main/default/lwc/**/*.js", "!**/__tests__/**"],
    coverageThreshold: {
        global: { statements: 75, branches: 60, functions: 70, lines: 75 }
    }
};
