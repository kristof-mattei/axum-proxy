/** @type {import("prettier").Config} */
export default {
    arrowParens: "always",
    bracketSpacing: true,
    printWidth: 120,
    quoteProps: "as-needed",
    semi: true,
    singleQuote: false,
    tabWidth: 4,
    trailingComma: "all",
    useTabs: false,
    overrides: [
        {
            files: ["**/*.ts", "**/*.tsx"],
            options: {
                parser: "typescript",
            },
        },
        {
            files: ["**/*.json"],
            options: {
                trailingComma: "none",
                printWidth: 80,
            },
        },
        {
            files: ["*.yaml", "*.yml"],
            options: {
                tabWidth: 2,
            },
        },
        {
            files: ["package.json", "package-lock.json"],
            options: {
                tabWidth: 2,
            },
        },
    ],
    plugins: ["prettier-plugin-sh"],
};
