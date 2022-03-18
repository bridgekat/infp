// Parsing :: Token, TokenID, NFALexer, DFALexer

#ifndef LEXER_HPP_
#define LEXER_HPP_

#include <vector>
#include <algorithm>
#include <optional>
#include <compare>
#include <string>


namespace Parsing {

  using std::vector;
  using std::pair, std::make_pair;
  using std::optional, std::make_optional, std::nullopt;
  using std::string;


  // Symbol ID
  using Symbol = unsigned int;

  // Parse tree node
  struct ParseTree {
    ParseTree* s, * c;
    Symbol id;
    optional<string> lexeme;    // Terminal symbols (tokens) only
    optional<size_t> ruleIndex; // Nonterminal symbols only
    size_t startPos, endPos;    // Measured in characters: [startPos, endPos)
  };

  // Also used as lexer token
  using Token = ParseTree;

  // A common (abstract) base class for lexers.
  class Lexer {
  public:
    // Error information
    struct ErrorInfo {
      size_t startPos, endPos;
      string lexeme;
      ErrorInfo(size_t startPos, size_t endPos, const std::string& lexeme):
        startPos(startPos), endPos(endPos), lexeme(lexeme) {}
    };

    virtual ~Lexer() = default;

    void setString(const string& s) { pos = 0; rest = s; }
    bool eof() const noexcept { return rest.empty(); }

    // All errors will be logged
    optional<Token> getNextToken();
    // Get and clear error log
    vector<ErrorInfo> popErrors();

  protected:
    Lexer(): pos(0), rest(), errors() {};

  private:
    size_t pos;
    string rest;
    vector<ErrorInfo> errors;

    // Returns longest match in the form of (length, token)
    virtual optional<pair<size_t, Symbol>> run(const string& s) const = 0;
  };

  // Implementation based on NFA. You may add patterns after construction.
  class NFALexer: public Lexer {
  public:
    typedef unsigned int State;
    typedef pair<State, State> NFA;

    // Create initial state
    NFALexer(): Lexer(), table(), initial(0) { table.emplace_back(); }

    #define node(x) State x = table.size(); table.emplace_back()
    #define trans(s, c, t) table[s].tr.emplace_back(c, t)

    // Add pattern (mark accepting state)
    void addPattern(Symbol id, NFA nfa) {
      trans(initial, 0, nfa.first);
      auto& o = table[nfa.second].ac;
      if (!o.has_value()) o = id;
    }

    // Some useful pattern constructors (equivalent to regexes)
    NFA epsilon() {
      node(s); node(t); trans(s, 0, t);
      return { s, t };
    }
    NFA ch(const vector<unsigned char>& ls) {
      node(s); node(t);
      for (auto c: ls) trans(s, c, t);
      return { s, t };
    }
    NFA range(unsigned char a, unsigned char b) {
      node(s); node(t);
      for (unsigned int i = a; i <= b; i++) trans(s, i, t);
      return { s, t };
    }
    NFA concat2(NFA a, NFA b) {
      for (auto [c, t]: table[b.first].tr) trans(a.second, c, t);
      return { a.first, b.second };
    }
    template <typename... Ts>
    NFA concat(NFA a, Ts... b) { return concat2(a, concat(b...)); }
    NFA concat(NFA a) { return a; }
    NFA word(const string& str) {
      node(s); State t = s;
      for (unsigned char c: str) {
        node(curr);
        trans(t, c, curr);
        t = curr;
      }
      return { s, t };
    }
    NFA alt(const vector<NFA>& ls) {
      node(s); node(t);
      for (auto a: ls) {
        trans(s, 0, a.first);
        trans(a.second, 0, t);
      }
      return { s, t };
    }
    NFA star(NFA a) {
      node(s); node(t);
      trans(s, 0, a.first); trans(a.second, 0, t);
      trans(a.second, 0, a.first); trans(s, 0, t);
      return { s, t };
    }
    NFA plus(NFA a)   { return concat2(a, star(a)); }
    NFA any()         { return range(0x01, 0xFF); }
    NFA utf8segment() { return range(0x80, 0xFF); }
    NFA except(const vector<unsigned char>& ls) {
      vector<bool> f(0x100, true);
      for (auto c: ls) f[c] = false;
      node(s); node(t);
      for (unsigned int i = 0x01; i <= 0xFF; i++) if (f[i]) trans(s, i, t);
      return { s, t };
    }

    #undef node
    #undef trans

    // Returns the size of the table
    size_t tableSize() { return table.size(); }

  private:
    // The transition & accepting state table
    struct Entry {
      vector<pair<unsigned char, State>> tr;
      optional<Symbol> ac;
      Entry(): tr(), ac() {}
    };
    vector<Entry> table;
    // The initial state
    State initial;

    // Returns longest match in the form of (length, token)
    optional<pair<size_t, Symbol>> run(const string& s) const override;

    friend class PowersetConstruction;
  };

  // Implementation based on DFA. Could only be constructed from an `NFALexer`.
  class DFALexer: public Lexer {
  public:
    typedef unsigned int State;

    // Create DFA from NFA
    explicit DFALexer(const NFALexer& nfa);

    // Optimize DFA
    void optimize();

    // Returns the size of the table
    size_t tableSize() { return table.size(); }

    // Convert lexer DFA to TextMate grammar JSON (based on regular expressions)
    // Following: https://macromates.com/manual/en/regular_expressions (only a simple subset is used)
    // (Not implemented)
    string toTextMateGrammar() const;

  private:
    // The transition & accepting state table
    struct Entry {
      bool has[0x100];
      State tr[0x100];
      optional<Symbol> ac;
      Entry(): has{}, tr{}, ac() {}
    };
    vector<Entry> table;
    // The initial state
    State initial;

    // Returns longest match in the form of (length, token)
    optional<pair<size_t, Symbol>> run(const string& s) const override;

    friend class PowersetConstruction;
    friend class PartitionRefinement;
  };

}

#endif // LEXER_HPP_
