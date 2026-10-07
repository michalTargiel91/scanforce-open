import { readFileSync, readdirSync } from 'node:fs';
import { ApexParserFactory, ApexErrorListener } from '@apexdevtools/apex-parser';

let errors = 0;
const directory = 'force-app/main/default/classes';
for (const file of readdirSync(directory).filter(name => name.endsWith('.cls'))) {
  class Listener extends ApexErrorListener {
    apexSyntaxError(line, column, message) {
      console.error(`${file}:${line}:${column}: ${message}`);
      errors++;
    }
  }
  const { parser } = ApexParserFactory.createLexerAndParser(
    readFileSync(`${directory}/${file}`, 'utf8'), new Listener(),
  );
  parser.compilationUnit();
}
if (errors) process.exit(1);
console.log('Apex syntax passed (org compilation and runtime tests still required).');
