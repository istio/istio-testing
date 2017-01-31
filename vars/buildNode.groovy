/*
Creates a node with the right label and checkout the source code.
*/

def call(gitUtils, Closure body) {
  def nodeLabel = params.get('SLAVE_LABEL')
  if (nodeLabel == null) {
    nodeLabel = gitUtils.DEFAULT_SLAVE_LABEL
  }
  def buildNodeLabel = "${nodeLabel}-build"
  node(buildNodeLabel) {
    gitUtils.checkoutSourceCode()
    body()
  }
}

return this