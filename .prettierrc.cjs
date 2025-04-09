/**
 * @type { import("prettier").Config }
 */
const prettierConfig = {
    arrowParens: "always",
    bracketSpacing: true,
    printWidth: 80,
    quoteProps: "as-needed",
    semi: true,
    singleQuote: false,
    useTabs: false,
    tabWidth: 4,
    trailingComma: "all",
    overrides: [
        {
            files: ["*.ts", "*.tsx"],
            options: {
                parser: "typescript",
            },
        },
        {
            files: ["*.cjs"],
        },
        {
            files: ["**/*.json"],
            options: {
                trailingComma: "none",
            },
        },
        {
            files: ["**/*.json"],
            options: {
                trailingComma: "none",
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

module.exports = prettierConfig;
