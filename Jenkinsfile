pipeline {
    agent any

    parameters {
        choice(
            name: 'ENVIRONMENT',
            choices: ['qa', 'prod'],
            description: 'Target deployment environment'
        )
        string(
            name: 'SERVICE_NAME',
            defaultValue: '',
            description: 'Service to deploy (e.g. dhanman-common). Leave blank to deploy all.'
        )
        booleanParam(
            name: 'RUN_INFRA',
            defaultValue: false,
            description: 'Re-run full infrastructure playbook (02-install-infra)'
        )
    }

    environment {
        ANSIBLE_HOST_KEY_CHECKING = 'False'
        ANSIBLE_FORCE_COLOR       = 'true'
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Validate') {
            steps {
                sh '''
                    ansible --version
                    ansible-lint --version 2>/dev/null || true
                '''
            }
        }

        stage('Build .NET') {
            when {
                expression { params.SERVICE_NAME != '' }
            }
            steps {
                dir("src/${params.SERVICE_NAME}") {
                    sh 'dotnet publish -c Release -o publish/'
                }
            }
        }

        stage('Copy Binaries') {
            when {
                expression { params.SERVICE_NAME != '' }
            }
            steps {
                script {
                    def inventory = "ansible/inventories/${params.ENVIRONMENT}"
                    def host = params.ENVIRONMENT == 'prod' ? '51.79.156.217' : '54.37.159.71'
                    def baseDir = params.ENVIRONMENT == 'prod' ? '/var/www/prod' : '/var/www/qa'

                    sh """
                        rsync -az --delete \
                            -e "ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa" \
                            src/${params.SERVICE_NAME}/publish/ \
                            ubuntu@${host}:${baseDir}/${params.SERVICE_NAME}/
                    """
                }
            }
        }

        stage('Infrastructure') {
            when {
                expression { params.RUN_INFRA }
            }
            steps {
                sh """
                    ansible-playbook \
                        -i ansible/inventories/${params.ENVIRONMENT} \
                        ansible/playbooks/02-install-infra.yml
                """
            }
        }

        stage('Deploy Service') {
            when {
                expression { params.SERVICE_NAME != '' }
            }
            steps {
                sh """
                    ansible-playbook \
                        -i ansible/inventories/${params.ENVIRONMENT} \
                        ansible/playbooks/deploy-service.yml \
                        -e service_name=${params.SERVICE_NAME}
                """
            }
        }

        stage('Deploy All Services') {
            when {
                expression { params.SERVICE_NAME == '' && !params.RUN_INFRA }
            }
            steps {
                sh """
                    ansible-playbook \
                        -i ansible/inventories/${params.ENVIRONMENT} \
                        ansible/playbooks/03-deploy-services.yml
                """
            }
        }
    }

    post {
        success {
            echo "Deployment to ${params.ENVIRONMENT} succeeded."
        }
        failure {
            echo "Deployment to ${params.ENVIRONMENT} FAILED. Check logs above."
        }
        always {
            cleanWs()
        }
    }
}
